//
//  AppModel+GeminiLive.swift
//  SpatialYOLO
//
//  Created by Claude on 2025/4/14.
//

import Foundation
import CoreImage
import UIKit

extension AppModel {

    /// 启动 AI Live 会话
    func startGeminiSession() {
        guard !isGeminiActive else { return }
        isGeminiActive = true

        // 注入系统提示词
        let finalInstruction = aiLiveSystemInstruction()
        let finalLanguage = aiConversationLanguage()
        activeService.systemInstruction = finalInstruction
        activeService.inputLanguage = finalLanguage
        print("[AI] 注入系统提示词 (模式:\(activeFeature)，语言:\(language)，长度:\(finalInstruction.count))")

        // Gemini 会话过期时自动重连
        geminiService.onSessionExpired = { [weak self] in
            guard let self = self, self.isGeminiActive else { return }
            print("[AI] 会话过期，2秒后自动重连...")
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self = self, self.isGeminiActive else { return }
                print("[AI] 正在自动重连...")
                self.activeService.connect()
            }
        }


        activeService.connect()

        bindOpenClawTranscriptMonitoring()

        // 开始录制会话帧
        sessionRecorder.startSession()
    }

    /// 停止 AI Live 会话
    func stopGeminiSession() {
        isGeminiActive = false
        activeService.disconnect()

        // 停止录制并重置场景状态
        sessionRecorder.stopSession()
        lastSentThumbnail = nil
        isVoiceSamplingActive = false
        audioTranscriptPreviewFrame = nil
        unbindOpenClawTranscriptMonitoring()
        lastTriggeredTranscript = ""
        lastObservedOpenClawTranscript = ""
    }

    /// 切换 AI Live 会话状态
    func toggleGeminiSession() {
        if isGeminiActive {
            stopGeminiSession()
        } else {
            startGeminiSession()
        }
    }

    /// 切换 AI 服务提供商（需要先断开当前会话）
    func switchProvider(to provider: AIProvider) {
        if isGeminiActive {
            stopGeminiSession()
        }
        activeProvider = provider
    }

    /// 构建当前帧结构化检测上下文文本（在主线程调用）
    func buildDetectionContext() -> String {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timeStr = formatter.string(from: now)
        let isEnglish = language == .english

        var lines: [String] = [isEnglish ? "[Frame Analysis] \(timeStr)" : "[帧分析] \(timeStr)"]

        // 物体检测（含空间位置）
        let objCount = boundingBoxesLeft.count
        if objCount > 0 {
            lines.append(
                isEnglish
                ? "[Object Detection] \(objCount) object\(objCount == 1 ? "" : "s"):"
                : "[物体检测] \(objCount) 个目标:"
            )
            for i in 0..<objCount {
                let cls = i < detectedClassesLeft.count ? detectedClassesLeft[i] : "unknown"
                let conf = i < confidencesLeft.count ? confidencesLeft[i] : 0

                // 空间位置：基于 Vision 归一化坐标（x: 0=左, 1=右）
                var posStr = ""
                if i < boundingBoxesLeft.count {
                    let box = boundingBoxesLeft[i]
                    let centerX = box.origin.x + box.width / 2.0
                    posStr = localizedSpatialPositionDescription(
                        centerX: centerX,
                        distanceMeters: i < objectDistanceMeters.count ? objectDistanceMeters[i] : nil
                    )
                }

                lines.append("  - \(cls) (\(Int(conf))%)\(posStr)")
            }
        } else {
            lines.append(isEnglish ? "[Object Detection] No objects detected" : "[物体检测] 未检测到目标")
        }

        // 人脸分析
        let faceCount = faceDetections.count
        if faceCount > 0 {
            lines.append(
                isEnglish
                ? "[Face Analysis] Detected \(faceCount) face\(faceCount == 1 ? "" : "s"):"
                : "[人脸分析] 检测到 \(faceCount) 张人脸:"
            )
            for (idx, face) in faceDetections.enumerated() {
                // 找主表情（最高分）
                let sorted = face.expressionScores.sorted { $0.value > $1.value }
                if let top = sorted.first {
                    let topStr = localizedFaceExpressionName(top.key)
                    let topPct = Int(top.value * 100)
                    let top3 = sorted.prefix(3)
                        .map { "\(localizedFaceExpressionName($0.key)):\(Int($0.value * 100))%" }
                        .joined(separator: ", ")
                    if isEnglish {
                        lines.append("  - Face \(idx + 1): expression=\(topStr) (\(topPct)%) [candidates: \(top3)]")
                    } else {
                        lines.append("  - 人脸\(idx + 1): 表情=\(topStr) (\(topPct)%) [候选: \(top3)]")
                    }
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    /// 将摄像头帧发送给 AI 服务（1fps 采样，在帧循环中调用）
    /// 压缩和发送在后台线程执行，不阻塞主线程帧循环
    func sendFrameToGemini(_ pixelBuffer: CVPixelBuffer) {
        guard isGeminiActive,
              activeService.connectionState == .connected else { return }

        // 在主线程构建检测上下文（需要访问主线程属性）
        let contextText = buildDetectionContext()
        print("\(language == .english ? "[Frame Analysis]" : "[帧分析]") \(contextText)")

        // CIImage 是轻量惰性对象，主线程创建安全且会 retain pixelBuffer
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let service = self.activeService
        let shouldAutoNarrate = self.autoNarrate
        let cooldown = self.narrationCooldown
        let threshold = self.sceneChangeThreshold
        let lastThumb = self.lastSentThumbnail
        let lastNarTime = self.lastNarrationTime
        let recorder = self.sessionRecorder
        let currentResponseText = self.activeService.responseText
        let appLanguage = self.language

        // 重型压缩工作放到后台线程
        Task.detached { [weak self] in
            // 先发送检测上下文，再发送视频帧
            service.sendDetectionContext(contextText)
            
            let ciContext = CIContext()
            guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

            let originalWidth = CGFloat(cgImage.width)
            let originalHeight = CGFloat(cgImage.height)
            let maxDimension: CGFloat = 1024
            let scale = min(maxDimension / originalWidth, maxDimension / originalHeight, 1.0)
            let targetWidth = Int(originalWidth * scale)
            let targetHeight = Int(originalHeight * scale)

            // CGContext 线程安全的缩放
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return }

            ctx.interpolationQuality = .medium
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

            guard let resizedCGImage = ctx.makeImage(),
                  let jpegData = UIImage(cgImage: resizedCGImage).jpegData(compressionQuality: 0.8) else { return }

            await MainActor.run {
                self?.lastProcessedFrame = jpegData
            }

            service.sendVideoFrame(jpegData: jpegData)

            // 录制帧到本地（含 AI 回复文本）
            recorder.saveFrame(jpegData: jpegData, context: contextText, responseText: currentResponseText)

            // 图像场景变化检测 (Auto 模式逻辑)
            var shouldNarrate = false

            if shouldAutoNarrate {
                let now = Date()
                if now.timeIntervalSince(lastNarTime) >= cooldown {
                    // 仅使用像素级变化检测 (MSE)
                    let thumbSize = 64
                    let colorSpaceRef = CGColorSpaceCreateDeviceRGB()
                    if let thumbCtx = CGContext(
                        data: nil, width: thumbSize, height: thumbSize,
                        bitsPerComponent: 8, bytesPerRow: thumbSize * 4,
                        space: colorSpaceRef,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                    ) {
                        thumbCtx.interpolationQuality = .low
                        thumbCtx.draw(cgImage, in: CGRect(x: 0, y: 0, width: thumbSize, height: thumbSize))

                        if let currentThumb = thumbCtx.makeImage() {
                            if let prevThumb = lastThumb {
                                let mse = SessionRecorder.computeImageMSE(prevThumb, currentThumb, size: thumbSize)
                                if mse > threshold {
                                    shouldNarrate = true
                                    print("[自动解说] 场景变化 MSE=\(String(format: "%.4f", mse))，触发解说")
                                }
                            } else {
                                // 首帧，触发初始解说
                                shouldNarrate = true
                                print("[自动解说] 首帧，触发初始解说")
                            }
                            
                            await MainActor.run {
                                self?.lastSentThumbnail = currentThumb
                            }
                        }
                    }

                    if shouldNarrate {
                        await MainActor.run {
                            self?.lastNarrationTime = now
                        }
                    }
                }
            }

            if shouldNarrate {
                service.sendTextMessage(
                    appLanguage == .english
                    ? "Please briefly describe what you can see right now."
                    : "请简要描述你现在看到的画面内容。"
                )
            }
        }
    }



    /// 发送用户提问
    func sendUserQuestion(_ text: String) {
        guard !text.isEmpty,
              isGeminiActive,
              activeService.connectionState == .connected else { return }

        activeService.sendTextMessage(text)
        userInputText = ""
    }

    private func localizedSpatialPositionDescription(centerX: CGFloat, distanceMeters: Float?) -> String {
        let isEnglish = language == .english
        let positionName: String
        if centerX < 0.33 {
            positionName = isEnglish ? "on the left" : "左侧"
        } else if centerX > 0.67 {
            positionName = isEnglish ? "on the right" : "右侧"
        } else {
            positionName = isEnglish ? "in front" : "正前方"
        }

        if let distanceMeters {
            if isEnglish {
                return ", \(positionName), about \(String(format: "%.1f", distanceMeters))m away"
            }
            return ", \(positionName)约\(String(format: "%.1f", distanceMeters))米"
        }

        return ", \(positionName)"
    }

    private func localizedFaceExpressionName(_ expression: FaceExpression) -> String {
        guard language != .english else {
            return expression.rawValue.capitalized
        }

        switch expression {
        case .happy:
            return "开心"
        case .sad:
            return "难过"
        case .angry:
            return "生气"
        case .surprised:
            return "惊讶"
        case .fear:
            return "害怕"
        case .disgust:
            return "厌恶"
        case .neutral:
            return "中性"
        }
    }

}

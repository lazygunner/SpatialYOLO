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

        // 根据当前模式注入独立的系统提示词
        let instruction = (activeFeature == .mahjong) ? aiLiveSystemInstruction() : aiLiveSystemInstruction()
        // 修正逻辑：由于 mahjongSystemInstruction 被命名为 mahjong... 我需要纠正这里的调用
        let finalInstruction = (activeFeature == .mahjong) ? mahjongSystemInstruction() : aiLiveSystemInstruction()
        activeService.systemInstruction = finalInstruction
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

        // 麻将模式下设置 Qwen 打牌事件回调
        if activeFeature == .mahjong {
            qwenService.onDiscardEvent = { [weak self] event in
                DispatchQueue.main.async {
                    self?.addDiscardEvent(event)
                }
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

        var lines: [String] = ["[帧分析] \(timeStr)"]

        // 物体检测（含空间位置）
        let objCount = boundingBoxesLeft.count
        if objCount > 0 {
            lines.append("[物体检测] \(objCount) 个目标:")
            for i in 0..<objCount {
                let cls = i < detectedClassesLeft.count ? detectedClassesLeft[i] : "unknown"
                let conf = i < confidencesLeft.count ? confidencesLeft[i] : 0

                // 空间位置：基于 Vision 归一化坐标（x: 0=左, 1=右）
                var posStr = ""
                if i < boundingBoxesLeft.count {
                    let box = boundingBoxesLeft[i]
                    let centerX = box.origin.x + box.width / 2.0
                    let posName: String
                    if centerX < 0.33 {
                        posName = "左侧"
                    } else if centerX > 0.67 {
                        posName = "右侧"
                    } else {
                        posName = "正前方"
                    }

                    if i < objectDistanceMeters.count, let d = objectDistanceMeters[i] {
                        posStr = ", \(posName)约\(String(format: "%.1f", d))米"
                    } else {
                        posStr = ", \(posName)"
                    }
                }

                lines.append("  - \(cls) (\(Int(conf))%)\(posStr)")
            }
        } else {
            lines.append("[物体检测] 未检测到目标")
        }

        // 人脸分析
        let faceCount = faceDetections.count
        if faceCount > 0 {
            lines.append("[人脸分析] 检测到 \(faceCount) 张人脸:")
            for (idx, face) in faceDetections.enumerated() {
                // 找主表情（最高分）
                let sorted = face.expressionScores.sorted { $0.value > $1.value }
                if let top = sorted.first {
                    let topStr = top.key.rawValue
                    let topPct = Int(top.value * 100)
                    // top3
                    let top3 = sorted.prefix(3).map { "\($0.key.rawValue):\(Int($0.value * 100))%" }.joined(separator: ", ")
                    lines.append("  - 人脸\(idx + 1): 表情=\(topStr) (\(topPct)%) [候选: \(top3)]")
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
        print("[帧分析] \(contextText)")

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

        let currentLabelsCapture = Set(self.detectedClassesLeft)

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
                service.sendTextMessage("请简要描述你现在看到的画面内容。")
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

    // MARK: - 牌局管理

    /// 开始新牌局：清空记忆，以当前检测为初始手牌
    func startMahjongGame() {
        mahjongHandMemory = mahjongDetections.map { $0.classCode }
        mahjongAbsenceCount = [:]
        discardRecords = []
        mahjongGameActive = true
        mahjongAnalysisService.resetConversation()
        print("[麻将] 牌局开始，初始手牌 \(mahjongHandMemory.count) 张")
    }

    /// 重置牌局：清空所有记忆
    func resetMahjongGame() {
        mahjongGameActive = false
        mahjongHandMemory = []
        mahjongAbsenceCount = [:]
        discardRecords = []
        mahjongAnalysisService.resetConversation()
        print("[麻将] 牌局已重置")
    }

    /// 使用独立 LLM (qwen-plus) 分析麻将牌型
    /// 牌局进行中使用记忆手牌，否则使用当前帧检测结果
    func sendMahjongAnalysis() {
        // 优先使用记忆手牌，否则用当前帧检测
        let codes: [String]
        if mahjongGameActive && !mahjongHandMemory.isEmpty {
            codes = mahjongHandMemory
        } else {
            codes = mahjongDetections.map { $0.classCode }
        }

        print("[麻将AI] 触发独立 LLM 分析: codes=\(codes.count)张, 打牌记录=\(discardRecords.count)位玩家")
        guard !codes.isEmpty else {
            print("[麻将AI] 无检测到的牌，取消分析"); return
        }
        guard !mahjongAnalysisService.isAnalyzing else {
            print("[麻将AI] 分析进行中，请稍候"); return
        }

        let records = discardRecords
        let service = mahjongAnalysisService
        Task {
            await service.analyze(
                handTiles: codes,
                tileNames: AppModel.mahjongClassNames,
                tileEmojis: AppModel.mahjongTileEmojis,
                discardRecords: records
            )
        }
    }

    // MARK: - 打牌记录管理

    /// 添加一条打牌事件（由 Omni 语音监听回调触发）
    func addDiscardEvent(_ event: DiscardEvent) {
        // 找到对应玩家的记录，没有则创建
        if let index = discardRecords.firstIndex(where: { $0.player == event.player }) {
            discardRecords[index].events.append(event)
        } else {
            discardRecords.append(PlayerDiscardRecord(player: event.player, events: [event]))
        }
        print("[麻将] 打牌记录: \(event.player) \(event.action) \(event.tile)")
    }

    /// 清空所有打牌记录
    func clearDiscardRecords() {
        discardRecords = []
        print("[麻将] 打牌记录已清空")
    }

}

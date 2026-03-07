//
//  SessionRecorder.swift
//  SpatialYOLO
//
//  AI Live 会话录制：保存视频帧、检测上下文和 AI 回复到本地
//

import Foundation
import UIKit

@Observable
class SessionRecorder {

    // MARK: - 状态

    var isRecording: Bool = false
    var frameCount: Int = 0
    var sessionID: String = ""

    // MARK: - Private

    private var sessionDir: URL?
    private var sessionStartTime: Date?
    private let locationManager = LocationManager()

    // MARK: - 会话管理

    /// 开始新的录制会话
    func startSession() {
        let id = UUID().uuidString.prefix(8).lowercased()
        sessionID = String(id)
        sessionStartTime = Date()
        frameCount = 0

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("sessions/\(sessionID)")

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            sessionDir = dir
            isRecording = true
            
            // 请求当前位置
            locationManager.requestLocation()

            // 保存 session 元数据
            let meta: [String: Any] = [
                "id": sessionID,
                "startTime": ISO8601DateFormatter().string(from: sessionStartTime!),
                "device": "Apple Vision Pro",
                "status": SessionStatus.pending.rawValue,
                "locationName": "正在获取位置..."
            ]
            let metaData = try JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted)
            try metaData.write(to: dir.appendingPathComponent("session.json"))

            print("[录制] 会话开始: \(sessionID)")
        } catch {
            print("[录制] 创建目录失败: \(error)")
        }
    }

    /// 停止录制会话
    func stopSession() {
        guard isRecording, let dir = sessionDir else { return }

        // --- 核心变更：如果没有照片帧，则不保存会话 ---
        if frameCount == 0 {
            print("[录制] 会话内无照片帧，放弃保存: \(sessionID)")
            try? FileManager.default.removeItem(at: dir)
            isRecording = false
            return
        }

        // 更新元数据
        let metaFile = dir.appendingPathComponent("session.json")
        if var meta = loadJSON(from: metaFile) {
            meta["endTime"] = ISO8601DateFormatter().string(from: Date())
            meta["frameCount"] = frameCount
            // 如果已经获取到位置，更新它
            if locationManager.currentLocationName != "未知地点" {
                meta["locationName"] = locationManager.currentLocationName
            } else if meta["locationName"] as? String == "正在获取位置..." {
                meta["locationName"] = "未知地点"
            }
            
            if let data = try? JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted) {
                try? data.write(to: metaFile)
            }
        }

        isRecording = false
        print("[录制] 会话结束: \(sessionID), 共 \(frameCount) 帧")
        
        // --- 自动开始后台异步处理 ---
        let finalSession = SessionInfo(
            id: sessionID,
            directory: dir,
            startTime: sessionStartTime ?? Date(),
            frameCount: frameCount,
            thumbnailURL: dir.appendingPathComponent("frame_0001.jpg"),
            sizeBytes: Self.directorySize(at: dir),
            status: .pending,
            cartoonImageURL: nil,
            locationName: locationManager.currentLocationName
        )
        
        Task {
            print("[处理] 正在自动启动后台处理...")
            await Self.processSession(finalSession)
        }
    }

    /// 保存一帧 JPEG、检测上下文和当前 AI 回复文本
    func saveFrame(jpegData: Data, context: String, responseText: String = "") {
        guard isRecording, let dir = sessionDir else { return }

        frameCount += 1
        let idx = String(format: "%04d", frameCount)

        // 后台保存，不阻塞主线程
        let frameFile = dir.appendingPathComponent("frame_\(idx).jpg")
        let textFile = dir.appendingPathComponent("frame_\(idx).txt")
        let aiFile = dir.appendingPathComponent("frame_\(idx).ai.txt")

        DispatchQueue.global(qos: .utility).async {
            do {
                try jpegData.write(to: frameFile)
                try context.write(to: textFile, atomically: true, encoding: .utf8)
                if !responseText.isEmpty {
                    try responseText.write(to: aiFile, atomically: true, encoding: .utf8)
                }
            } catch {
                print("[录制] 保存帧失败: \(error)")
            }
        }
    }

    // MARK: - 会话列表

    /// 获取所有已录制的会话
    static func listSessions() -> [SessionInfo] {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let sessionsDir = docs.appendingPathComponent("sessions")

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        var sessions: [SessionInfo] = []
        let isoFormatter = ISO8601DateFormatter()

        for dir in contents {
            let metaFile = dir.appendingPathComponent("session.json")
            guard let data = try? Data(contentsOf: metaFile),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = meta["id"] as? String,
                  let startStr = meta["startTime"] as? String,
                  let startTime = isoFormatter.date(from: startStr) else { continue }

            let frameCount = meta["frameCount"] as? Int ?? 0
            let statusRaw = meta["status"] as? String ?? SessionStatus.pending.rawValue
            let status = SessionStatus(rawValue: statusRaw) ?? .pending
            
            // 优先查找是否存在卡通图封面
            let cartoonFile = dir.appendingPathComponent("cartoon.jpg")
            let cartoonExists = FileManager.default.fileExists(atPath: cartoonFile.path)
            let cartoonURL = cartoonExists ? cartoonFile : nil

            // 查找第一帧作为缩略图
            let thumbFile = dir.appendingPathComponent("frame_0001.jpg")
            let thumbExists = FileManager.default.fileExists(atPath: thumbFile.path)

            // 计算会话目录大小
            let dirSize = Self.directorySize(at: dir)
            
            let locationName = meta["locationName"] as? String ?? "未知地点"

            sessions.append(SessionInfo(
                id: id,
                directory: dir,
                startTime: startTime,
                frameCount: frameCount,
                thumbnailURL: thumbExists ? thumbFile : nil,
                sizeBytes: dirSize,
                status: status,
                cartoonImageURL: cartoonURL,
                locationName: locationName
            ))
        }

        return sessions.sorted { $0.startTime > $1.startTime }
    }

    // MARK: - 帧列表

    /// 获取指定会话的所有帧信息，自动将相似帧合并（保留第一张图像，但合并所有 AI 回复）
    static func listFrames(in directory: URL, groupSimilar: Bool = true) async -> [FrameInfo] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        let jpegFiles = contents
            .filter { $0.pathExtension == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let rawFrames = jpegFiles.map { jpegURL -> FrameInfo in
            let baseName = jpegURL.deletingPathExtension().lastPathComponent
            let textURL = directory.appendingPathComponent("\(baseName).txt")
            let aiURL = directory.appendingPathComponent("\(baseName).ai.txt")
            let context = (try? String(contentsOf: textURL, encoding: .utf8)) ?? ""
            let aiResponse = (try? String(contentsOf: aiURL, encoding: .utf8)) ?? ""

            return FrameInfo(
                imageURL: jpegURL,
                context: context,
                aiResponse: aiResponse,
                name: baseName
            )
        }

        guard groupSimilar, !rawFrames.isEmpty else { return rawFrames }

        var grouped: [FrameInfo] = []
        var lastThumb: CGImage?
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        for frame in rawFrames {
            var isSimilar = false
            
            if let data = try? Data(contentsOf: frame.imageURL),
               let uiImage = UIImage(data: data),
               let cgImage = uiImage.cgImage {
                
                // 将缩略图尺寸缩小到 64x64，以便在比较时保留更多结构变化
                let thumbSize = 64
                if let thumbCtx = CGContext(
                    data: nil, width: thumbSize, height: thumbSize,
                    bitsPerComponent: 8, bytesPerRow: thumbSize * 4,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                ) {
                    thumbCtx.interpolationQuality = .low
                    thumbCtx.draw(cgImage, in: CGRect(x: 0, y: 0, width: thumbSize, height: thumbSize))
                    
                    if let currentThumb = thumbCtx.makeImage() {
                        if let prevThumb = lastThumb {
                            let mse = SessionRecorder.computeImageMSE(prevThumb, currentThumb, size: thumbSize)
                            
                            // MSE 值通常很小，0.08 太激进了。在0~1范围内，0.005及以下通常代表几乎没动。
                            // 这里改用一个更严格的阈值（比如 0.005）
                            if mse < 0.005 { 
                                isSimilar = true
                            }
                        }
                        
                        // 不相似，则更新基准缩略图
                        if !isSimilar {
                            lastThumb = currentThumb
                        }
                    }
                }
            }
            
            if isSimilar && !grouped.isEmpty {
                // 如果是相似场景，只更新 AI 文本（丢弃重复图像）
                if frame.hasAIResponse {
                    let lastIndex = grouped.count - 1
                    var mergedAI = grouped[lastIndex].aiResponse
                    
                    // 为了避免完全重复的话被一直累加，做一个简单的去重
                    let currentResp = frame.aiResponse.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !currentResp.isEmpty && !mergedAI.contains(currentResp) {
                        if !mergedAI.isEmpty { mergedAI += "\n\n" }
                        mergedAI += currentResp
                        grouped[lastIndex].aiResponse = mergedAI
                    }
                }
            } else {
                // 新场景第一张，保留
                grouped.append(frame)
            }
        }

        return grouped
    }

    // MARK: - 处理回忆

    /// 处理回忆（合并帧、调用API生成卡通图）
    static func processSession(_ session: SessionInfo) async {
        let dir = session.directory
        let metaFile = dir.appendingPathComponent("session.json")
        var meta = loadJSON(from: metaFile) ?? [:]
        
        // 1. 更新状态为处理中
        meta["status"] = SessionStatus.processing.rawValue
        saveJSON(meta, to: metaFile)
        
        // 2. 合并相似帧
        let rawFrames = await listFrames(in: dir, groupSimilar: false)
        let mergedFrames = await listFrames(in: dir, groupSimilar: true)
        
        // 删除不需要的原始帧
        let mergedNames = Set(mergedFrames.map { $0.name })
        for frame in rawFrames {
            if !mergedNames.contains(frame.name) {
                try? FileManager.default.removeItem(at: frame.imageURL)
                let textURL = dir.appendingPathComponent("\(frame.name).txt")
                let aiURL = dir.appendingPathComponent("\(frame.name).ai.txt")
                try? FileManager.default.removeItem(at: textURL)
                try? FileManager.default.removeItem(at: aiURL)
            }
        }
        
        // 将合并后的 AI 回复覆盖写回文件
        for frame in mergedFrames {
            if !frame.aiResponse.isEmpty {
                let aiURL = dir.appendingPathComponent("\(frame.name).ai.txt")
                try? frame.aiResponse.write(to: aiURL, atomically: true, encoding: .utf8)
            }
        }
        
        // 更新元数据中的帧数
        meta["frameCount"] = mergedFrames.count
        saveJSON(meta, to: metaFile)
        
        // 3. 调用 Nano Banana API 生成卡通图
        if let firstFrame = mergedFrames.first {
            print("[处理] 准备为 \(firstFrame.name) 生成卡通图...")
            
            if let cartoonURL = await generateCartoonCover(for: firstFrame, in: dir) {
                // 4. 更新状态为已完成
                meta["status"] = SessionStatus.completed.rawValue
                meta["cartoonImageURL"] = cartoonURL.absoluteString
                saveJSON(meta, to: metaFile)
                print("[处理] 会话 \(session.id) 处理完成，已生成卡通图！")
            } else {
                print("[处理] 生成卡通图失败，标记为完成但无封面。")
                meta["status"] = SessionStatus.completed.rawValue
                saveJSON(meta, to: metaFile)
            }
        } else {
            // 没有帧的情况，直接标记完成
            meta["status"] = SessionStatus.completed.rawValue
            saveJSON(meta, to: metaFile)
            print("[处理] 会话 \(session.id) 无帧，直接标记完成。")
        }
    }

    // MARK: - 卡通图生成 (Nano Banana API / Gemini 3.1 Flash Image Preview)

    /// 调用 Gemini API 的 gemini-3.1-flash-image-preview 模型生成卡通封面
    private static func generateCartoonCover(for frame: FrameInfo, in sessionDir: URL) async -> URL? {
        let apiKey = await MainActor.run { AppModel.loadGeminiAPIKey() }
        guard !apiKey.isEmpty else {
            print("[卡通图] 错误：未配置 Gemini API Key")
            return nil
        }

        // 构造 Prompt：基于该帧的 AI 回复来生成卡通画
        // 如果没有 AI 回复，就使用一段通用的描述
        let contextDesc = ""
        // 去除换行，尽量变成一句顺畅的话
        let cleanContext = contextDesc.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        
        let prompt = "A cute, high-quality, vibrant cartoon illustration of the following scene: \(cleanContext). The style should be like a modern 3D miniature animation, colorful and expressive."
        print("[卡通图] Prompt: \(prompt)")

        // 使用对应的模型和节点：gemini-3.1-flash-image-preview
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-image-preview:generateContent?key=\(apiKey)"
        guard let url = URL(string: endpoint) else { return nil }

        // 读取原图帧的 Bae64 用于作为参考图生成
        var base64Image = ""
        if let data = try? Data(contentsOf: frame.imageURL) {
            base64Image = data.base64EncodedString()
        }

        var parts: [[String: Any]] = [
            ["text": prompt]
        ]

        if !base64Image.isEmpty {
            parts.append([
                "inlineData": [
                    "mimeType": "image/jpeg",
                    "data": base64Image
                ]
            ])
        }

        // 构造生成请求体 (Gemini 标准格式)
        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": parts
                ]
            ],
            "generationConfig": [
                "responseModalities": ["IMAGE"]
            ]
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: requestBody, options: []) else {
            print("[卡通图] 错误：无法编码请求体")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                print("[卡通图] 网络响应无效")
                return nil
            }
            if httpResponse.statusCode != 200 {
                let errorStr = String(data: data, encoding: .utf8) ?? "未知错误"
                print("[卡通图] API 错误 (\(httpResponse.statusCode)): \(errorStr)")
                return nil
            }

            // 解析返回的 JSON 
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first,
                  let content = firstCandidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let firstPart = parts.first,
                  let inlineData = firstPart["inlineData"] as? [String: Any],
                  let bytesBase64 = inlineData["data"] as? String else {
                print("[卡通图] 解析响应失败，找不到图片数据")
                return nil
            }

            // 解码 Base64 图片数据
            guard let imageData = Data(base64Encoded: bytesBase64, options: .ignoreUnknownCharacters) else {
                print("[卡通图] Base64 解码失败")
                return nil
            }

            // 保存到会话目录
            let cartoonURL = sessionDir.appendingPathComponent("cartoon.jpg")
            try imageData.write(to: cartoonURL)
            print("[卡通图] 已保存生成结果到: \(cartoonURL.lastPathComponent)")
            return cartoonURL

        } catch {
            print("[卡通图] 请求异常: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 删除会话

    /// 删除指定会话
    static func deleteSession(_ session: SessionInfo) {
        do {
            try FileManager.default.removeItem(at: session.directory)
            print("[录制] 已删除会话: \(session.id)")
        } catch {
            print("[录制] 删除会话失败: \(error)")
        }
    }

    // MARK: - 存储大小

    /// 计算所有会话总占用空间
    static func totalStorageSize() -> Int64 {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let sessionsDir = docs.appendingPathComponent("sessions")
        return directorySize(at: sessionsDir)
    }

    /// 格式化存储大小显示
    static func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// 递归计算目录大小
    private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// 计算两个等尺寸 CGImage 的像素 MSE（均方误差）
    static func computeImageMSE(_ a: CGImage, _ b: CGImage, size: Int) -> Float {
        let bytesPerRow = size * 4
        let totalBytes = bytesPerRow * size
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        var bufA = [UInt8](repeating: 0, count: totalBytes)
        var bufB = [UInt8](repeating: 0, count: totalBytes)

        guard let ctxA = CGContext(data: &bufA, width: size, height: size,
                                    bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                    space: colorSpace, bitmapInfo: bitmapInfo),
              let ctxB = CGContext(data: &bufB, width: size, height: size,
                                    bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                    space: colorSpace, bitmapInfo: bitmapInfo)
        else { return 1.0 }

        ctxA.draw(a, in: CGRect(x: 0, y: 0, width: size, height: size))
        ctxB.draw(b, in: CGRect(x: 0, y: 0, width: size, height: size))

        var sumSqDiff: Float = 0
        let pixelCount = size * size
        for i in 0..<pixelCount {
            let offset = i * 4
            for c in 1...3 {
                let diff = Float(bufA[offset + c]) - Float(bufB[offset + c])
                sumSqDiff += diff * diff
            }
        }

        return sumSqDiff / Float(pixelCount * 3) / (255.0 * 255.0)
    }

    // MARK: - Helpers

    private static func loadJSON(from url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    private func loadJSON(from url: URL) -> [String: Any]? {
        return Self.loadJSON(from: url)
    }

    private static func saveJSON(_ dict: [String: Any], to url: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) {
            try? data.write(to: url)
        }
    }
}

// MARK: - 数据模型

enum SessionStatus: String {
    case pending
    case processing
    case completed
}

struct SessionInfo: Identifiable {
    let id: String
    let directory: URL
    let startTime: Date
    let frameCount: Int
    let thumbnailURL: URL?
    let sizeBytes: Int64
    let status: SessionStatus
    let cartoonImageURL: URL?
    let locationName: String
}

struct FrameInfo: Identifiable {
    let id = UUID()
    let imageURL: URL
    let context: String
    var aiResponse: String   // AI 回复文本（有内容说明该帧有 AI 返回，var 允许合并）
    let name: String

    /// 该帧是否有 AI 回复
    var hasAIResponse: Bool { !aiResponse.isEmpty }
}

//
//  GeminiLiveService.swift
//  SpatialYOLO
//
//  Created by Claude on 2025/4/14.
//

import Foundation
import AVFoundation
import CoreImage
import UIKit

/// Gemini Live API WebSocket 通信服务
/// 管理与 Gemini 的实时双向通信，包括视频帧发送、文字/音频响应接收
@Observable
class GeminiLiveService: RealtimeAIService {

    // MARK: - 连接状态

    var connectionState: AIConnectionState = .disconnected

    // MARK: - 响应数据

    var responseText: String = ""          // 当前回合的文字响应（流式累加）
    var responseHistory: [String] = []     // 历史响应记录
    var isModelSpeaking: Bool = false      // 模型是否正在生成

    // MARK: - 会话管理

    var sessionStartTime: Date?
    var sessionRemainingSeconds: Int = 120  // 2分钟会话限制

    // MARK: - 系统提示词（由外部注入，各模式独立）

    var systemInstruction: String = ""

    // MARK: - Private

    private let apiKey: String
    private let model = "models/gemini-2.5-flash-native-audio-preview-12-2025"
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var sessionTimer: Task<Void, Never>?

    // 音频播放（输出 24kHz）
    private var audioEngine: AVAudioEngine?
    private var audioPlayerNode: AVAudioPlayerNode?
    private let outputAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24000,
        channels: 1,
        interleaved: true
    )!

    // 麦克风录制（输入 16kHz，参考 doc/live-api-video.md: SEND_SAMPLE_RATE = 16000）
    private let inputAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!
    private var audioConverter: AVAudioConverter?

    // MARK: - Init

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: - 连接管理

    /// 建立 WebSocket 连接并发送 setup 消息
    func connect() {
        guard connectionState != .connecting && connectionState != .connected else { return }

        connectionState = .connecting

        let endpoint = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(apiKey)"

        guard let url = URL(string: endpoint) else {
            connectionState = .error("无效的 API 端点")
            return
        }

        print("[GeminiLive] 正在连接: \(url.host ?? "unknown")\(url.path)")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30       // 初始连接握手超时
        config.timeoutIntervalForResource = 300     // WebSocket 长连接，5 分钟资源超时
        let delegate = WebSocketDelegate()
        delegate.onError = { [weak self] message in
            DispatchQueue.main.async {
                guard let self = self, self.connectionState == .connected || self.connectionState == .connecting else { return }
                print("[GeminiLive] Delegate 报告错误，更新连接状态")
                self.connectionState = .error(message)
            }
        }
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        webSocketTask = session.webSocketTask(with: url)

        print("[GeminiLive] WebSocket task 创建完成，调用 resume()...")
        webSocketTask?.resume()

        // 发送 setup 消息
        sendSetupMessage()

        // 开始接收消息
        startReceiving()

        // 启动音频引擎
        setupAudioEngine()
    }

    /// 断开 WebSocket 连接
    func disconnect() {
        print("[GeminiLive] 断开连接")
        receiveTask?.cancel()
        receiveTask = nil
        sessionTimer?.cancel()
        sessionTimer = nil

        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil

        stopAudioEngine()

        connectionState = .disconnected
        isModelSpeaking = false
        responseText = ""
        responseHistory = []
        sessionStartTime = nil
        sessionRemainingSeconds = 120
        framesSent = 0
    }

    // MARK: - 发送消息

    /// 发送视频帧到 Gemini
    /// - Parameter imageData: JPEG 压缩后的图像数据
    /// 帧发送计数
    var framesSent: Int = 0

    func sendVideoFrame(jpegData: Data) {
        guard connectionState == .connected else { return }
        framesSent += 1
        if framesSent % 10 == 1 {
            print("[GeminiLive] 已发送 \(framesSent) 帧 (\(jpegData.count / 1024)KB)")
        }

        let base64String = jpegData.base64EncodedString()

        let message: [String: Any] = [
            "realtimeInput": [
                "mediaChunks": [
                    [
                        "mimeType": "image/jpeg",
                        "data": base64String
                    ]
                ]
            ]
        ]

        sendJSON(message)
    }

    /// 发送结构化检测上下文（turnComplete=false，不触发响应）
    func sendDetectionContext(_ text: String) {
        guard connectionState == .connected else { return }

        let message: [String: Any] = [
            "clientContent": [
                "turns": [
                    [
                        "role": "user",
                        "parts": [
                            ["text": text]
                        ]
                    ]
                ],
                "turnComplete": false
            ]
        ]
        sendJSON(message)
    }

    /// 发送用户文字消息
    func sendTextMessage(_ text: String) {
        guard connectionState == .connected else {
            print("[GeminiLive] 发送失败: 连接未就绪 (state=\(connectionState))")
            return
        }
        let timestamp = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
        print("[GeminiLive] [\(timestamp)] 发送用户消息(\(text.count)字): \(text.prefix(80))")

        let message: [String: Any] = [
            "clientContent": [
                "turns": [
                    [
                        "role": "user",
                        "parts": [
                            ["text": text]
                        ]
                    ]
                ],
                "turnComplete": true
            ]
        ]

        sendJSON(message)

        // 清空当前响应，准备接收新回复
        responseText = ""
        isModelSpeaking = true
    }

    // MARK: - Private 方法

    /// 发送 setup 配置消息（使用外部注入的 systemInstruction）
    private func sendSetupMessage() {
        print("[GeminiLive] 发送 setup 消息 (model: \(model))...")
        let instruction = systemInstruction.isEmpty
            ? "你是 Apple Vision Pro 上的智能助手，请用中文简洁回答。"
            : systemInstruction
        let setupMessage: [String: Any] = [
            "setup": [
                "model": model,
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "speechConfig": [
                        "voiceConfig": [
                            "prebuiltVoiceConfig": [
                                "voiceName": "Zephyr"
                            ]
                        ]
                    ]
                ],
                "outputAudioTranscription": [:],
                "systemInstruction": [
                    "parts": [
                        ["text": instruction]
                    ]
                ]
            ]
        ]

        sendJSON(setupMessage)
    }

    /// 发送 JSON 消息
    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let jsonString = String(data: data, encoding: .utf8) else {
            print("[GeminiLive] JSON 序列化失败")
            return
        }

        // 调试：打印 setup 消息内容
        if dict["setup"] != nil {
            if let prettyData = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
               let prettyString = String(data: prettyData, encoding: .utf8) {
                print("[GeminiLive] Setup JSON:\n\(prettyString)")
            }
        }

        webSocketTask?.send(.string(jsonString)) { [weak self] error in
            if let error = error {
                let nsError = error as NSError
                print("[GeminiLive] 发送失败: \(nsError.domain) \(nsError.code) - \(nsError.localizedDescription)")
                DispatchQueue.main.async {
                    self?.connectionState = .error("发送失败(code:\(nsError.code)): \(nsError.localizedDescription)")
                }
            }
        }
    }

    /// 开始循环接收服务器消息
    private func startReceiving() {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self, let webSocketTask = self.webSocketTask else { break }

                do {
                    let message = try await webSocketTask.receive()
                    await self.handleMessage(message)
                } catch {
                    if !Task.isCancelled {
                        let nsError = error as NSError
                        print("[GeminiLive] 接收错误: \(error.localizedDescription)")
                        print("[GeminiLive] 错误域: \(nsError.domain), 代码: \(nsError.code)")
                        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                            print("[GeminiLive] 底层错误: \(underlyingError.domain) \(underlyingError.code) - \(underlyingError.localizedDescription)")
                        }
                        print("[GeminiLive] WebSocket closeCode: \(String(describing: webSocketTask.closeCode.rawValue)), closeReason: \(String(describing: webSocketTask.closeReason.map { String(data: $0, encoding: .utf8) }))")
                        await MainActor.run { [weak self] in
                            self?.connectionState = .error("连接失败(code:\(nsError.code)): \(error.localizedDescription)")
                        }
                    }
                    break
                }
            }
        }
    }

    /// 处理收到的 WebSocket 消息
    @MainActor
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseServerMessage(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseServerMessage(text)
            }
        @unknown default:
            break
        }
    }

    /// 解析服务器 JSON 消息
    @MainActor
    private func parseServerMessage(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[GeminiLive] JSON 解析失败")
            return
        }

        // 处理 setupComplete
        if json["setupComplete"] != nil {
            print("[GeminiLive] Setup 完成，连接就绪")
            connectionState = .connected
            sessionStartTime = Date()
            startSessionTimer()
            return
        }

        // 处理 serverContent
        if let serverContent = json["serverContent"] as? [String: Any] {
            // 打印 serverContent 的所有顶层 key
            let contentKeys = serverContent.keys.sorted().joined(separator: ", ")
            print("[GeminiLive] serverContent keys: [\(contentKeys)]")
            handleServerContent(serverContent)
            return
        }

        // 处理 goAway（服务器即将断开）
        if json["goAway"] != nil {
            print("[GeminiLive] 服务器通知即将断开")
            disconnect()
            return
        }

        // 打印未识别的顶层消息类型
        let topKeys = json.keys.sorted().joined(separator: ", ")
        print("[GeminiLive] 未识别消息 keys: [\(topKeys)]")
    }

    /// 处理 serverContent 响应
    @MainActor
    private func handleServerContent(_ content: [String: Any]) {
        // 解析 modelTurn
        if let modelTurn = content["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {

            for part in parts {
                // 文字响应（包含 thought）
                if let text = part["text"] as? String {
                    responseText += text
                    isModelSpeaking = true
                    print("[GeminiLive] 收到 text: \(text.prefix(100))")
                }

                // 音频转录
                if let transcript = part["transcript"] as? String {
                    responseText += transcript
                    isModelSpeaking = true
                    print("[GeminiLive] 收到 transcript: \(transcript.prefix(100))")
                }

                // 音频数据
                if let inlineData = part["inlineData"] as? [String: Any],
                   let mimeType = inlineData["mimeType"] as? String,
                   mimeType.hasPrefix("audio/") {
                    if let base64Audio = inlineData["data"] as? String,
                       let audioData = Data(base64Encoded: base64Audio) {
                        playAudioData(audioData)
                    }
                }
            }
        }

        // 检查 turnComplete
        if let turnComplete = content["turnComplete"] as? Bool, turnComplete {
            isModelSpeaking = false
            print("[GeminiLive] 回合完成, responseText长度: \(responseText.count)")
            // 不清空 responseText，历史字幕持续保留
            // 添加换行分隔符，后续回复 append 到后面
            if !responseText.isEmpty {
                responseText += "\n"
            }
        }

        // 检查是否被中断
        if let interrupted = content["interrupted"] as? Bool, interrupted {
            isModelSpeaking = false
            print("[GeminiLive] 被中断")
        }
    }

    // MARK: - 会话计时器

    private func startSessionTimer() {
        sessionTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒

                guard let self = self, let startTime = self.sessionStartTime else { break }

                let elapsed = Date().timeIntervalSince(startTime)
                let remaining = max(0, 120 - Int(elapsed))

                await MainActor.run {
                    self.sessionRemainingSeconds = remaining
                }

                // 会话超时，自动断开
                if remaining <= 0 {
                    await MainActor.run {
                        self.disconnect()
                    }
                    break
                }
            }
        }
    }

    // MARK: - 音频引擎（播放 + 录制）

    private func setupAudioEngine() {
        // 配置 Audio Session：同时录制和播放
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat)
            try session.setActive(true)
            print("[GeminiLive] Audio session: playAndRecord + voiceChat")
        } catch {
            print("[GeminiLive] Audio session 配置失败: \(error)")
        }

        audioEngine = AVAudioEngine()
        audioPlayerNode = AVAudioPlayerNode()

        guard let engine = audioEngine, let player = audioPlayerNode else { return }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputAudioFormat)

        // 安装麦克风输入 tap
        setupMicrophoneInput(engine: engine)

        do {
            try engine.start()
            player.play()
            print("[GeminiLive] 音频引擎启动（播放 + 录制）")
        } catch {
            print("[GeminiLive] 音频引擎启动失败: \(error)")
        }
    }

    // MARK: - 麦克风录制

    private func setupMicrophoneInput(engine: AVAudioEngine) {
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        print("[GeminiLive] 麦克风原始格式: \(nativeFormat.sampleRate)Hz, \(nativeFormat.channelCount)ch, \(nativeFormat.commonFormat.rawValue)")

        guard let converter = AVAudioConverter(from: nativeFormat, to: inputAudioFormat) else {
            print("[GeminiLive] 无法创建音频格式转换器")
            return
        }
        self.audioConverter = converter

        // 安装 tap 捕获麦克风音频
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            self?.processAndSendMicAudio(buffer: buffer)
        }
        print("[GeminiLive] 麦克风 tap 已安装")
    }

    /// 将麦克风音频转换为 16kHz PCM 并发送给 Gemini
    private func processAndSendMicAudio(buffer: AVAudioPCMBuffer) {
        guard connectionState == .connected, let converter = audioConverter else { return }

        let ratio = inputAudioFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard outputFrameCount > 0,
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: inputAudioFormat, frameCapacity: outputFrameCount) else { return }

        // 转换格式：native → 16kHz Int16 mono
        var hasProvided = false
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasProvided {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasProvided = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = error {
            print("[GeminiLive] 音频转换错误: \(error)")
            return
        }

        guard outputBuffer.frameLength > 0,
              let channelData = outputBuffer.int16ChannelData else { return }

        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        let pcmData = Data(bytes: channelData[0], count: byteCount)

        sendAudioChunk(pcmData: pcmData)
    }

    /// 发送音频数据到 Gemini
    private func sendAudioChunk(pcmData: Data) {
        guard connectionState == .connected else { return }

        let base64String = pcmData.base64EncodedString()
        let message: [String: Any] = [
            "realtimeInput": [
                "mediaChunks": [
                    [
                        "mimeType": "audio/pcm",
                        "data": base64String
                    ]
                ]
            ]
        ]

        sendJSON(message)
    }

    // MARK: - 音频播放

    private func stopAudioEngine() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioPlayerNode?.stop()
        audioEngine?.stop()
        audioPlayerNode = nil
        audioEngine = nil
        audioConverter = nil
    }

    /// 播放 Gemini 返回的 PCM 音频数据（24kHz）
    private func playAudioData(_ data: Data) {
        guard let player = audioPlayerNode, let engine = audioEngine, engine.isRunning else { return }

        let frameCount = UInt32(data.count) / outputAudioFormat.streamDescription.pointee.mBytesPerFrame
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: outputAudioFormat, frameCapacity: frameCount) else { return }

        buffer.frameLength = frameCount

        data.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                memcpy(buffer.int16ChannelData![0], baseAddress, data.count)
            }
        }

        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    // MARK: - 中文文字提取

    /// 从 thought 文本中提取中文字符和标点，过滤英文推理内容
    static func extractChinese(from text: String) -> String {
        var result = ""
        var inChineseRun = false

        for char in text {
            if char.isChinese {
                result.append(char)
                inChineseRun = true
            } else if inChineseRun && (char == " " || char == "\n") {
                // 中文段落内的空格/换行保留
                result.append(char)
            } else {
                inChineseRun = false
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Character 中文判断

private extension Character {
    /// 是否为中文字符或中文标点
    var isChinese: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        let v = scalar.value
        return (0x4E00...0x9FFF).contains(v)   // CJK 基本
            || (0x3400...0x4DBF).contains(v)   // CJK 扩展 A
            || (0xF900...0xFAFF).contains(v)   // CJK 兼容
            || (0x3000...0x303F).contains(v)   // CJK 标点
            || (0xFF01...0xFF5E).contains(v)   // 全角字符
            || "，。！？、：；\u{201C}\u{201D}\u{2018}\u{2019}（）「」【】—…·".contains(self)
    }
}

// MARK: - WebSocket 连接诊断代理

private class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {

    var onError: ((String) -> Void)?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("[GeminiLive] WebSocket 已打开, protocol: \(`protocol` ?? "none")")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        print("[GeminiLive] WebSocket 已关闭, closeCode: \(closeCode.rawValue), reason: \(reasonStr)")
        onError?("WebSocket 已关闭 (code:\(closeCode.rawValue)): \(reasonStr)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            let nsError = error as NSError
            print("[GeminiLive] URLSession task 完成, 错误: \(nsError.domain) \(nsError.code) - \(nsError.localizedDescription)")
            if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                print("[GeminiLive] 底层错误: \(underlyingError.domain) \(underlyingError.code) - \(underlyingError.localizedDescription)")
            }
            for (key, value) in nsError.userInfo where key != NSUnderlyingErrorKey {
                print("[GeminiLive] userInfo[\(key)]: \(value)")
            }
            onError?(nsError.localizedDescription)
        } else {
            print("[GeminiLive] URLSession task 正常完成")
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        print("[GeminiLive] TLS 认证挑战: \(challenge.protectionSpace.authenticationMethod), host: \(challenge.protectionSpace.host)")
        completionHandler(.performDefaultHandling, nil)
    }
}

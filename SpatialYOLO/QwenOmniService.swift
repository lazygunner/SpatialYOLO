//
//  QwenOmniService.swift
//  SpatialYOLO
//
//  Created by Claude on 2025/4/17.
//

import Foundation
import AVFoundation

/// Qwen Omni Realtime WebSocket 通信服务
/// 管理与 Qwen 的实时双向通信，包括视频帧发送、音频录制/播放、文字响应接收
@Observable
class QwenOmniService: RealtimeAIService {

    // MARK: - 连接状态

    var connectionState: AIConnectionState = .disconnected

    // MARK: - 响应数据

    var responseText: String = ""
    var isModelSpeaking: Bool = false

    /// 打牌事件回调（通知 AppModel 更新记录）
    var onDiscardEvent: ((DiscardEvent) -> Void)?

    /// 累积的当前回合完整转录文本（用于打牌事件解析）
    private var currentTurnTranscript: String = ""

    // MARK: - 会话管理

    var sessionStartTime: Date?
    var sessionRemainingSeconds: Int = 7200  // 120分钟
    var framesSent: Int = 0

    // MARK: - 系统提示词（由外部注入，各模式独立）

    var systemInstruction: String = ""

    // MARK: - Private

    private let apiKey: String
    private let model = "qwen3-omni-flash-realtime-2025-12-01"
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var sessionTimer: Task<Void, Never>?
    private var hasSentAudio = false  // Qwen 要求先发音频再发图像

    // 音频播放（服务端输出 24kHz PCM24，转换为 PCM16 后播放）
    private var audioEngine: AVAudioEngine?
    private var audioPlayerNode: AVAudioPlayerNode?
    private let outputPlayFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24000,
        channels: 1,
        interleaved: true
    )!

    // 麦克风录制（输入 16kHz PCM16 mono）
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

    func connect() {
        guard connectionState != .connecting && connectionState != .connected else { return }

        connectionState = .connecting
        hasSentAudio = false

        let endpoint = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=\(model)"

        guard let url = URL(string: endpoint) else {
            connectionState = .error("无效的 API 端点")
            return
        }

        print("[QwenOmni] 正在连接: \(url.host ?? "unknown")")

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 7500  // 120 分钟 + 余量
        let delegate = QwenWebSocketDelegate()
        delegate.onError = { [weak self] message in
            DispatchQueue.main.async {
                guard let self = self, self.connectionState == .connected || self.connectionState == .connecting else { return }
                print("[QwenOmni] Delegate 报告错误: \(message)")
                self.connectionState = .error(message)
            }
        }
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        webSocketTask = session.webSocketTask(with: request)

        print("[QwenOmni] WebSocket task 创建完成，调用 resume()...")
        webSocketTask?.resume()

        // 发送 session.update
        sendSessionUpdate()

        // 开始接收消息
        startReceiving()

        // 启动音频引擎
        setupAudioEngine()
    }

    func disconnect() {
        print("[QwenOmni] 断开连接")
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
        sessionStartTime = nil
        sessionRemainingSeconds = 7200
        framesSent = 0
        hasSentAudio = false
    }

    // MARK: - 发送消息

    func sendVideoFrame(jpegData: Data) {
        guard connectionState == .connected else { return }

        // Qwen 要求先发送至少一段音频后再发图像
        guard hasSentAudio else {
            print("[QwenOmni] 等待首次音频发送后再发送图像")
            return
        }

        framesSent += 1
        if framesSent % 10 == 1 {
            print("[QwenOmni] 已发送 \(framesSent) 帧 (\(jpegData.count / 1024)KB)")
        }

        let base64String = jpegData.base64EncodedString()
        let message: [String: Any] = [
            "type": "input_image_buffer.append",
            "image": base64String
        ]

        sendJSON(message)
    }

    /// 发送结构化检测上下文（不调用 response.create，不干扰 VAD）
    func sendDetectionContext(_ text: String) {
        guard connectionState == .connected else { return }
        // Qwen 要求先发音频，未发音频前跳过
        guard hasSentAudio else { return }

        let itemMessage: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": text
                    ]
                ]
            ]
        ]
        sendJSON(itemMessage)
        // 注意：不调用 response.create，让 VAD 自然触发响应
    }

    func sendTextMessage(_ text: String) {
        guard connectionState == .connected else {
            print("[QwenOmni] 发送失败: 连接未就绪 (state=\(connectionState))")
            return
        }
        let timestamp = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
        print("[QwenOmni] [\(timestamp)] 发送用户消息(\(text.count)字): \(text.prefix(80))")

        // 打断当前播放（仅在模型正在回复时）
        if isModelSpeaking {
            audioPlayerNode?.stop()
            audioPlayerNode?.play()
            isModelSpeaking = false
            sendJSON(["type": "response.cancel"])
        }

        // 清空音频缓冲区，防止 VAD 在响应生成期间误检测"说话"导致打断
        sendJSON(["type": "input_audio_buffer.clear"])

        // Qwen 使用 conversation.item.create + response.create
        // 必须顺序发送：先等 item.create 成功再发 response.create
        let itemMessage: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": text
                    ]
                ]
            ]
        ]
        sendJSON(itemMessage) { [weak self] in
            guard let self = self else { return }
            // item.create 发送完毕后再触发响应
            let responseMessage: [String: Any] = [
                "type": "response.create",
                "response": [
                    "modalities": ["text", "audio"]
                ]
            ]
            self.sendJSON(responseMessage)
        }

        isModelSpeaking = true
    }

    // MARK: - Private 方法

    private func sendSessionUpdate() {
        print("[QwenOmni] 发送 session.update...")
        let instruction = systemInstruction.isEmpty
            ? "你是 Apple Vision Pro 上的智能助手，请用中文简洁回答。"
            : systemInstruction
        let message: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["text", "audio"],
                "voice": "Cherry",
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm24",
                "instructions": instruction,
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "silence_duration_ms": 800
                ]
            ]
        ]

        sendJSON(message)
    }

    /// 发送 JSON 消息（带完成回调，用于顺序发送）
    private func sendJSON(_ dict: [String: Any], completion: (() -> Void)? = nil) {
        let msgType = dict["type"] as? String ?? "unknown"

        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let jsonString = String(data: data, encoding: .utf8) else {
            print("[QwenOmni] JSON 序列化失败 (type=\(msgType))")
            completion?()
            return
        }

        // 详细打印 session.update
        if msgType == "session.update" {
            if let prettyData = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
               let prettyString = String(data: prettyData, encoding: .utf8) {
                print("[QwenOmni] Session Update JSON:\n\(prettyString)")
            }
        }

        // 非高频消息（音频/图像除外）打印发送日志
        let silentTypes: Set = ["input_audio_buffer.append", "input_image_buffer.append"]
        if !silentTypes.contains(msgType) {
            print("[QwenOmni] >>> 发送: \(msgType) (\(jsonString.count) bytes)")
        }

        webSocketTask?.send(.string(jsonString)) { [weak self] error in
            if let error = error {
                let nsError = error as NSError
                print("[QwenOmni] 发送失败[\(msgType)]: \(nsError.localizedDescription)")
                DispatchQueue.main.async {
                    self?.connectionState = .error("发送失败: \(nsError.localizedDescription)")
                }
            } else if !silentTypes.contains(msgType) {
                print("[QwenOmni] >>> 发送成功: \(msgType)")
            }
            completion?()
        }
    }

    // MARK: - 接收消息

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
                        print("[QwenOmni] 接收错误: \(error.localizedDescription)")
                        print("[QwenOmni] WebSocket closeCode: \(String(describing: webSocketTask.closeCode.rawValue))")
                        await MainActor.run { [weak self] in
                            self?.connectionState = .error("连接失败: \(error.localizedDescription)")
                        }
                    }
                    break
                }
            }
        }
    }

    @MainActor
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseServerEvent(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseServerEvent(text)
            }
        @unknown default:
            break
        }
    }

    @MainActor
    private func parseServerEvent(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[QwenOmni] JSON 解析失败")
            return
        }

        guard let eventType = json["type"] as? String else {
            let keys = json.keys.sorted().joined(separator: ", ")
            print("[QwenOmni] 未识别事件 keys: [\(keys)]")
            return
        }

        switch eventType {
        case "session.created":
            print("[QwenOmni] 会话已创建")

        case "session.updated":
            print("[QwenOmni] 会话配置已更新，连接就绪")
            connectionState = .connected
            sessionStartTime = Date()
            startSessionTimer()

        case "response.audio.delta":
            // 音频数据
            if let delta = json["delta"] as? String,
               let audioData = Data(base64Encoded: delta) {
                playAudioData(audioData)
            }
            isModelSpeaking = true

        case "response.audio_transcript.delta":
            // 音频转录（中文文字）
            if let delta = json["delta"] as? String {
                responseText += delta
                currentTurnTranscript += delta
                isModelSpeaking = true
                print("[QwenOmni] transcript: \(delta.prefix(50))")
            }

        case "response.text.delta":
            // 纯文字响应
            if let delta = json["delta"] as? String {
                responseText += delta
                currentTurnTranscript += delta
                isModelSpeaking = true
                print("[QwenOmni] text: \(delta.prefix(50))")
            }

        case "response.created":
            print("[QwenOmni] 响应已创建 (response.created) ✅")

        case "response.output_item.added":
            if let item = json["item"] as? [String: Any] {
                let itemType = item["type"] as? String ?? "unknown"
                print("[QwenOmni] 输出项已添加: type=\(itemType)")
            }

        case "response.output_item.done":
            print("[QwenOmni] 输出项完成")

        case "conversation.item.created":
            if let item = json["item"] as? [String: Any] {
                let role = item["role"] as? String ?? "unknown"
                print("[QwenOmni] 对话项已创建: role=\(role)")
            }

        case "rate_limits.updated":
            print("[QwenOmni] 速率限制更新")

        case "response.audio.done":
            print("[QwenOmni] 音频生成完成 ✅")

        case "response.audio_transcript.done":
            if let transcript = json["transcript"] as? String {
                print("[QwenOmni] 音频转录完成: \(transcript.prefix(60))")
            } else {
                print("[QwenOmni] 音频转录完成")
            }

        case "response.text.done":
            if let text = json["text"] as? String {
                print("[QwenOmni] 文字响应完成: \(text.prefix(60))")
            } else {
                print("[QwenOmni] 文字响应完成")
            }

        case "response.done":
            isModelSpeaking = false
            print("[QwenOmni] 回合完成, responseText长度: \(responseText.count)")

            // 解析当前回合的转录文本，提取打牌事件
            if !currentTurnTranscript.isEmpty {
                parseDiscardEvents(from: currentTurnTranscript)
                currentTurnTranscript = ""
            }

            if !responseText.isEmpty {
                responseText += "\n"
            }

        case "input_audio_buffer.speech_started":
            print("[QwenOmni] VAD: 检测到用户开始说话")
            // 打断当前播放（barge-in）
            if isModelSpeaking {
                print("[QwenOmni] 用户打断，停止当前播放")
                audioPlayerNode?.stop()
                audioPlayerNode?.play() // 重置播放器，准备接收新音频
                isModelSpeaking = false
            }

        case "input_audio_buffer.speech_stopped":
            print("[QwenOmni] VAD: 检测到用户停止说话")

        case "response.cancelled":
            print("[QwenOmni] 响应被取消（用户打断）")
            isModelSpeaking = false

        case "conversation.item.input_audio_transcription.completed":
            if let transcript = json["transcript"] as? String {
                print("[QwenOmni] 用户语音转录: \(transcript)")
                if !transcript.isEmpty {
                    responseText += "🗣 \(transcript)\n"
                }
            }

        case "error":
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                print("[QwenOmni] 服务器错误: \(message)")
                connectionState = .error(message)
            }

        default:
            print("[QwenOmni] 事件: \(eventType)")
        }
    }

    // MARK: - 会话计时器

    private func startSessionTimer() {
        sessionTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)

                guard let self = self, let startTime = self.sessionStartTime else { break }

                let elapsed = Date().timeIntervalSince(startTime)
                let remaining = max(0, 7200 - Int(elapsed))

                await MainActor.run {
                    self.sessionRemainingSeconds = remaining
                }

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
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat)
            try session.setActive(true)
            print("[QwenOmni] Audio session: playAndRecord + voiceChat")
        } catch {
            print("[QwenOmni] Audio session 配置失败: \(error)")
        }

        audioEngine = AVAudioEngine()
        audioPlayerNode = AVAudioPlayerNode()

        guard let engine = audioEngine, let player = audioPlayerNode else { return }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputPlayFormat)

        setupMicrophoneInput(engine: engine)

        do {
            try engine.start()
            player.play()
            print("[QwenOmni] 音频引擎启动（播放 + 录制）")
        } catch {
            print("[QwenOmni] 音频引擎启动失败: \(error)")
        }
    }

    // MARK: - 麦克风录制

    private func setupMicrophoneInput(engine: AVAudioEngine) {
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        print("[QwenOmni] 麦克风原始格式: \(nativeFormat.sampleRate)Hz, \(nativeFormat.channelCount)ch")

        guard let converter = AVAudioConverter(from: nativeFormat, to: inputAudioFormat) else {
            print("[QwenOmni] 无法创建音频格式转换器")
            return
        }
        self.audioConverter = converter

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            self?.processAndSendMicAudio(buffer: buffer)
        }
        print("[QwenOmni] 麦克风 tap 已安装")
    }

    private func processAndSendMicAudio(buffer: AVAudioPCMBuffer) {
        guard connectionState == .connected, let converter = audioConverter else { return }

        let ratio = inputAudioFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard outputFrameCount > 0,
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: inputAudioFormat, frameCapacity: outputFrameCount) else { return }

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
            print("[QwenOmni] 音频转换错误: \(error)")
            return
        }

        guard outputBuffer.frameLength > 0,
              let channelData = outputBuffer.int16ChannelData else { return }

        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        let pcmData = Data(bytes: channelData[0], count: byteCount)

        sendAudioChunk(pcmData: pcmData)
    }

    private func sendAudioChunk(pcmData: Data) {
        guard connectionState == .connected else { return }

        if !hasSentAudio {
            hasSentAudio = true
            print("[QwenOmni] 首次音频已发送，现在可以发送图像")
        }

        let base64String = pcmData.base64EncodedString()
        let message: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64String
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

    /// 播放 Qwen 返回的 PCM 音频数据（24kHz, 16-bit, mono）
    /// pcm24 指 24kHz 采样率，数据格式仍为 16-bit signed int little-endian
    private func playAudioData(_ data: Data) {
        guard let player = audioPlayerNode, let engine = audioEngine, engine.isRunning else { return }

        let frameCount = UInt32(data.count) / outputPlayFormat.streamDescription.pointee.mBytesPerFrame
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: outputPlayFormat, frameCapacity: frameCount) else { return }

        buffer.frameLength = frameCount

        data.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                memcpy(buffer.int16ChannelData![0], baseAddress, data.count)
            }
        }

        player.scheduleBuffer(buffer, completionHandler: nil)
    }
    // MARK: - 打牌事件解析

    /// 从 Omni 的转录文本中提取结构化打牌事件
    /// 格式: [玩家X] 打 三万 / [玩家X] 碰 / [玩家X] 杠 东风 / [玩家X] 胡
    private func parseDiscardEvents(from text: String) {
        let lines = text.components(separatedBy: CharacterSet.newlines)
        let pattern = #"\[(.+?)\]\s*(打|碰|杠|吃|胡)\s*(.*)"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if let match = regex.firstMatch(in: trimmed, range: range) {
                let player = String(trimmed[Range(match.range(at: 1), in: trimmed)!])
                let action = String(trimmed[Range(match.range(at: 2), in: trimmed)!])
                let tile = match.range(at: 3).location != NSNotFound
                    ? String(trimmed[Range(match.range(at: 3), in: trimmed)!]).trimmingCharacters(in: .whitespaces)
                    : ""

                let event = DiscardEvent(
                    player: player,
                    tile: tile,
                    action: action,
                    timestamp: Date()
                )

                print("[QwenOmni] 解析打牌事件: \(player) \(action) \(tile)")
                onDiscardEvent?(event)
            }
        }
    }
}

// MARK: - WebSocket Delegate

private class QwenWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {

    var onError: ((String) -> Void)?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("[QwenOmni] WebSocket 已打开")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        print("[QwenOmni] WebSocket 已关闭, closeCode: \(closeCode.rawValue), reason: \(reasonStr)")
        onError?("WebSocket 已关闭 (code:\(closeCode.rawValue)): \(reasonStr)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            let nsError = error as NSError
            print("[QwenOmni] URLSession task 错误: \(nsError.localizedDescription)")
            onError?(nsError.localizedDescription)
        }
    }
}

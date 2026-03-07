//
//  AudioInputMonitor.swift
//  SpatialYOLO
//
//  独立音频输入监测：
//    - 自主 AVAudioEngine（.default 模式，可捕获环境语音）
//    - 波形可视化：RMS 计算，60 条滚动振幅历史
//    - 本地 STT：SFSpeechRecognizer，自动重启
//    - 独立开关，不随 Live API 联动
//

import Foundation
import AVFoundation
import Speech
import Accelerate

@Observable
class AudioInputMonitor {

    // MARK: - 状态

    var isActive: Bool = false   // 用户手动开关

    // MARK: - 波形数据（主线程，60 条振幅历史）

    static let barCount = 60
    var waveformBars: [Float] = Array(repeating: 0, count: barCount)
    var inputLevel: Float = 0

    // MARK: - 本地 STT

    enum STTStatus: Equatable {
        case idle
        case requesting
        case active
        case unavailable
        case error(String)
    }

    var sttStatus: STTStatus = .idle
    var localTranscript: String = ""
    var committedTranscript: String = ""

    // MARK: - Private — 音频引擎

    private var audioEngine: AVAudioEngine?
    private var rmsAccumulator: [Float] = []
    private let framesPerBar = 5

    // MARK: - Private — STT

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isRestarting = false
    private var committedHistory: [String] = []
    private let maxHistoryLines = 2

    // MARK: - 开关

    func toggle() {
        if isActive {
            stopEngine()
        } else {
            startEngine()
        }
    }

    // MARK: - 引擎生命周期

    private func startEngine() {
        DispatchQueue.main.async {
            self.sttStatus = .requesting
            self.isActive = true
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                switch status {
                case .authorized:
                    self.doStartEngine()
                default:
                    self.sttStatus = .unavailable
                    self.isActive = false
                    print("[STT] 权限未授权: \(status.rawValue)")
                }
            }
        }
    }

    private func doStartEngine() {
        do {
            let session = AVAudioSession.sharedInstance()
            // .default 模式（非 voiceChat），不加声学回声消除和波束成形，可捕获环境语音
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .mixWithOthers])
            try session.setActive(true)
        } catch {
            print("[STT] AudioSession 配置失败: \(error)")
            sttStatus = .error(error.localizedDescription)
            isActive = false
            return
        }

        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }

        do {
            try engine.start()
            print("[STT] 独立音频引擎已启动 (mode: default，可捕获环境语音)")
        } catch {
            print("[STT] 音频引擎启动失败: \(error)")
            engine.inputNode.removeTap(onBus: 0)
            audioEngine = nil
            sttStatus = .error(error.localizedDescription)
            isActive = false
            return
        }

        waveformBars = Array(repeating: 0, count: Self.barCount)
        inputLevel = 0
        localTranscript = ""
        committedTranscript = ""
        committedHistory = []
        rmsAccumulator.removeAll()

        startRecognition()
    }

    private func stopEngine() {
        stopRecognition()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        DispatchQueue.main.async {
            self.isActive = false
            self.sttStatus = .idle
            self.waveformBars = Array(repeating: 0, count: Self.barCount)
            self.inputLevel = 0
            self.localTranscript = ""
        }
    }

    // MARK: - 处理音频缓冲（tap 回调，非主线程）

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        let rms = computeRMS(buffer)
        rmsAccumulator.append(rms)
        if rmsAccumulator.count >= framesPerBar {
            let avg = rmsAccumulator.reduce(0, +) / Float(rmsAccumulator.count)
            rmsAccumulator.removeAll()
            let normalized = min(avg * 18.0, 1.0)
            pushBar(normalized)
        }
        recognitionRequest?.append(buffer)
    }

    // MARK: - 波形

    private func pushBar(_ value: Float) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.waveformBars.removeFirst()
            self.waveformBars.append(value)
            self.inputLevel = value
        }
    }

    private func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        if let floatData = buffer.floatChannelData {
            var rms: Float = 0
            vDSP_rmsqv(floatData[0], 1, &rms, vDSP_Length(frameCount))
            return rms
        }
        if let int16Data = buffer.int16ChannelData {
            let ptr = int16Data[0]
            var sumSq: Float = 0
            for i in 0..<frameCount {
                let s = Float(ptr[i]) / 32768.0
                sumSq += s * s
            }
            return sqrt(sumSq / Float(frameCount))
        }
        return 0
    }

    // MARK: - STT

    private func startRecognition() {
        let recognizer: SFSpeechRecognizer?
        if let zh = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), zh.isAvailable {
            recognizer = zh
        } else if let sys = SFSpeechRecognizer(), sys.isAvailable {
            recognizer = sys
        } else {
            sttStatus = .unavailable
            print("[STT] 无可用语音识别器")
            return
        }

        speechRecognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        recognitionTask = recognizer!.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async { self.localTranscript = text }

                if result.isFinal {
                    if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                        self.committedHistory.append(text)
                        if self.committedHistory.count > self.maxHistoryLines {
                            self.committedHistory.removeFirst()
                        }
                        DispatchQueue.main.async {
                            self.committedTranscript = self.committedHistory.joined(separator: "\n")
                            self.localTranscript = ""
                        }
                    }
                    self.scheduleRestart()
                }
            }

            if let error {
                let nsError = error as NSError
                let silentCodes: Set<Int> = [203, 209, 216, 301, 1101]
                if !silentCodes.contains(nsError.code) {
                    print("[STT] 错误 \(nsError.code): \(nsError.localizedDescription)")
                    DispatchQueue.main.async { self.sttStatus = .error(nsError.localizedDescription) }
                }
                self.scheduleRestart()
            }
        }

        DispatchQueue.main.async {
            self.sttStatus = .active
            print("[STT] 识别已启动 (locale: \(recognizer!.locale.identifier))")
        }
    }

    private func stopRecognition() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        speechRecognizer = nil
        isRestarting = false
    }

    private func scheduleRestart() {
        guard !isRestarting else { return }
        isRestarting = true
        stopRecognition()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.isActive else { return }
            self.isRestarting = false
            self.startRecognition()
        }
    }
}

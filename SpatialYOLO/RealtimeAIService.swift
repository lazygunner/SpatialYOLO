//
//  RealtimeAIService.swift
//  SpatialYOLO
//
//  Created by Claude on 2025/4/17.
//

import Foundation

/// AI 服务连接状态
enum AIConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

/// AI 服务提供商
enum AIProvider: String, CaseIterable {
    case gemini = "Gemini"
    case qwen = "Qwen"
}

enum AIConversationLanguage {
    case chinese
    case english

    var contextHeader: String {
        switch self {
        case .chinese:
            return "[当前视觉检测上下文]"
        case .english:
            return "[Current Visual Context]"
        }
    }

    var userMessageHeader: String {
        switch self {
        case .chinese:
            return "[用户消息]"
        case .english:
            return "[User Message]"
        }
    }
}

// MARK: - 麻将打牌记录数据结构

/// 单次打牌事件
struct DiscardEvent: Identifiable {
    let id = UUID()
    let player: String      // "玩家A" / "玩家B" / "玩家C"
    let tile: String         // 牌名 "三万"
    let action: String       // "打" / "吃" / "碰" / "杠" / "胡"
    let timestamp: Date
}

/// 按玩家分组的打牌记录
struct PlayerDiscardRecord: Identifiable {
    let id = UUID()
    let player: String
    var events: [DiscardEvent]
}

/// 实时多模态 AI 服务协议
/// Gemini Live 和 Qwen Omni 都遵循此协议
protocol RealtimeAIService: Observable, AnyObject {
    var connectionState: AIConnectionState { get }
    var responseText: String { get set }
    var isModelSpeaking: Bool { get }
    var sessionRemainingSeconds: Int { get }
    var sessionStartTime: Date? { get }
    var framesSent: Int { get }
    var inputLanguage: AIConversationLanguage { get set }

    /// 系统提示词，由外部在 connect() 前注入，各模式独立
    var systemInstruction: String { get set }



    func connect()
    func disconnect()
    func sendVideoFrame(jpegData: Data)
    func sendTextMessage(_ text: String)

    /// 发送当前帧结构化检测上下文（在视频帧之前调用）
    func sendDetectionContext(_ text: String)
}

enum TranscriptSpeaker {
    case user
    case model

    var prefix: String {
        switch self {
        case .user:
            return "🗣 "
        case .model:
            return ""
        }
    }
}

struct TranscriptRoleUpdate {
    let committedLines: [String]
    let currentFragment: String
}

struct TranscriptRoleAccumulator {
    private var rawText: String = ""
    private var committedSentenceCount: Int = 0
    private(set) var currentFragment: String = ""

    mutating func reset() {
        rawText = ""
        committedSentenceCount = 0
        currentFragment = ""
    }

    mutating func replaceCumulative(with text: String) -> TranscriptRoleUpdate {
        rawText = text
        return process()
    }

    mutating func appendDelta(_ text: String) -> TranscriptRoleUpdate {
        rawText += text
        return process()
    }

    mutating func finalizeCurrentFragment() -> String? {
        let fragment = currentFragment
        reset()
        return fragment.isEmpty ? nil : fragment
    }

    private mutating func process() -> TranscriptRoleUpdate {
        let parsed = TranscriptSentenceParser.parse(rawText)
        let committed = Array(parsed.sentences.dropFirst(committedSentenceCount))
        committedSentenceCount = parsed.sentences.count
        currentFragment = parsed.currentFragment
        return TranscriptRoleUpdate(
            committedLines: committed,
            currentFragment: currentFragment
        )
    }
}

struct TranscriptConversationFormatter {
    private var committedLines: [String] = []
    private var activeSpeaker: TranscriptSpeaker?
    private var userAccumulator = TranscriptRoleAccumulator()
    private var modelAccumulator = TranscriptRoleAccumulator()

    mutating func reset() -> String {
        committedLines = []
        activeSpeaker = nil
        userAccumulator.reset()
        modelAccumulator.reset()
        return ""
    }

    mutating func replaceCumulative(_ text: String, speaker: TranscriptSpeaker) -> String {
        prepareForIncomingUpdate(from: speaker)
        let update: TranscriptRoleUpdate
        switch speaker {
        case .user:
            update = userAccumulator.replaceCumulative(with: text)
        case .model:
            update = modelAccumulator.replaceCumulative(with: text)
        }
        appendCommittedLines(update.committedLines, speaker: speaker)
        return renderedText()
    }

    mutating func appendDelta(_ text: String, speaker: TranscriptSpeaker) -> String {
        prepareForIncomingUpdate(from: speaker)
        let update: TranscriptRoleUpdate
        switch speaker {
        case .user:
            update = userAccumulator.appendDelta(text)
        case .model:
            update = modelAccumulator.appendDelta(text)
        }
        appendCommittedLines(update.committedLines, speaker: speaker)
        return renderedText()
    }

    mutating func finalize(_ speaker: TranscriptSpeaker) -> String {
        let fragment: String?
        switch speaker {
        case .user:
            fragment = userAccumulator.finalizeCurrentFragment()
        case .model:
            fragment = modelAccumulator.finalizeCurrentFragment()
        }

        if let fragment, !fragment.isEmpty {
            committedLines.append(formatted(fragment, speaker: speaker))
        }
        if activeSpeaker == speaker {
            activeSpeaker = nil
        }
        return renderedText()
    }

    private mutating func prepareForIncomingUpdate(from speaker: TranscriptSpeaker) {
        if let activeSpeaker, activeSpeaker != speaker {
            _ = finalize(activeSpeaker)
        }
        self.activeSpeaker = speaker
    }

    private mutating func appendCommittedLines(_ lines: [String], speaker: TranscriptSpeaker) {
        guard !lines.isEmpty else { return }
        committedLines.append(contentsOf: lines.map { formatted($0, speaker: speaker) })
    }

    private func renderedText() -> String {
        var lines = committedLines
        if let activeLine = activeLineText() {
            lines.append(activeLine)
        }
        return lines.joined(separator: "\n")
    }

    private func activeLineText() -> String? {
        guard let activeSpeaker else { return nil }

        let fragment: String
        switch activeSpeaker {
        case .user:
            fragment = userAccumulator.currentFragment
        case .model:
            fragment = modelAccumulator.currentFragment
        }

        guard !fragment.isEmpty else { return nil }
        return formatted(fragment, speaker: activeSpeaker)
    }

    private func formatted(_ text: String, speaker: TranscriptSpeaker) -> String {
        speaker.prefix + text
    }
}

enum TranscriptSentenceParser {
    static func parse(_ text: String) -> (sentences: [String], currentFragment: String) {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        var sentences: [String] = []
        var current = ""

        for character in flattened {
            current.append(character)
            if isSentenceTerminator(character) {
                let normalized = normalize(current)
                if !normalized.isEmpty {
                    sentences.append(normalized)
                }
                current = ""
            }
        }

        return (
            sentences,
            normalize(current)
        )
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSentenceTerminator(_ character: Character) -> Bool {
        switch character {
        case "。", "！", "？", ".", "!", "?", ";", "；":
            return true
        default:
            return false
        }
    }
}

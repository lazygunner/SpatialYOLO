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

    /// 系统提示词，由外部在 connect() 前注入，各模式独立
    var systemInstruction: String { get set }



    func connect()
    func disconnect()
    func sendVideoFrame(jpegData: Data)
    func sendTextMessage(_ text: String)

    /// 发送当前帧结构化检测上下文（在视频帧之前调用）
    func sendDetectionContext(_ text: String)
}

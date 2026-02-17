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

/// 实时多模态 AI 服务协议
/// Gemini Live 和 Qwen Omni 都遵循此协议
protocol RealtimeAIService: Observable, AnyObject {
    var connectionState: AIConnectionState { get }
    var responseText: String { get set }
    var isModelSpeaking: Bool { get }
    var sessionRemainingSeconds: Int { get }
    var sessionStartTime: Date? { get }
    var framesSent: Int { get }

    func connect()
    func disconnect()
    func sendVideoFrame(jpegData: Data)
    func sendTextMessage(_ text: String)
}

//
//  GeminiResponseView.swift
//  SpatialYOLO
//
//  Created by Claude on 2025/4/14.
//

import SwiftUI

/// Gemini Live 控制面板
/// 连接状态、会话倒计时、用户文字输入、启停控制
struct GeminiResponseView: View {
    @Bindable var appModel: AppModel

    var body: some View {
        VStack(spacing: 12) {
            // 顶部状态栏
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)

                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                // 会话倒计时
                if appModel.isGeminiActive {
                    Text(formattedRemainingTime)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(
                            appModel.geminiService.sessionRemainingSeconds <= 30
                            ? .red : .secondary
                        )
                }
            }
            .padding(.horizontal, 12)

            Divider()

            // 状态提示
            if appModel.isGeminiActive {
                if appModel.geminiService.isModelSpeaking {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text("AI 正在回复...")
                            .font(.body)
                            .foregroundColor(.white)
                    }
                } else {
                    Text("语音对话中，直接说话即可")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .italic()
                }
            } else {
                Text("点击下方按钮启动 Gemini 助手")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .italic()
            }

            Spacer()

            Divider()

            // 用户文字输入区域
            HStack(spacing: 8) {
                TextField("向 AI 提问...", text: $appModel.userInputText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        appModel.sendUserQuestion(appModel.userInputText)
                    }
                    .disabled(!appModel.isGeminiActive
                              || appModel.geminiService.connectionState != .connected)

                Button {
                    appModel.sendUserQuestion(appModel.userInputText)
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(appModel.userInputText.isEmpty
                          || !appModel.isGeminiActive
                          || appModel.geminiService.connectionState != .connected)
            }
            .padding(.horizontal, 12)

            // 按钮区域
            HStack(spacing: 8) {
                Button {
                    appModel.toggleGeminiSession()
                } label: {
                    HStack {
                        Image(systemName: appModel.isGeminiActive ? "stop.circle.fill" : "play.circle.fill")
                        Text(appModel.isGeminiActive ? "停止" : "启动")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(appModel.isGeminiActive ? .red : .blue)

                if showRetryButton {
                    Button {
                        appModel.stopGeminiSession()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            appModel.startGeminiSession()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.clockwise.circle.fill")
                            Text("重试")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .padding(.vertical, 8)
        .frame(width: 960, height: 240)
        .glassBackgroundEffect()
    }

    // MARK: - Computed Properties

    private var showRetryButton: Bool {
        switch appModel.geminiService.connectionState {
        case .error:
            return true
        case .disconnected:
            // 会话超时后自动断开的情况
            return appModel.geminiService.sessionRemainingSeconds <= 0
        default:
            return false
        }
    }

    private var statusColor: Color {
        switch appModel.geminiService.connectionState {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .gray
        case .error: return .red
        }
    }

    private var statusText: String {
        switch appModel.geminiService.connectionState {
        case .connected: return "已连接"
        case .connecting: return "连接中..."
        case .disconnected: return "未连接"
        case .error(let msg): return "错误: \(msg)"
        }
    }

    private var formattedRemainingTime: String {
        let minutes = appModel.geminiService.sessionRemainingSeconds / 60
        let seconds = appModel.geminiService.sessionRemainingSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

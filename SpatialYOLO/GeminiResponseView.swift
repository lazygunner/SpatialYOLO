//
//  GeminiResponseView.swift
//  SpatialYOLO
//
//  AI Live 控制面板（JARVIS HUD 风格）
//

import SwiftUI

/// AI Live 控制面板（HUD 风格）
/// 连接状态、会话倒计时、服务商切换、用户文字输入、启停控制
struct GeminiResponseView: View {
    @Bindable var appModel: AppModel

    @State private var dotPulse: Bool = false

    private var service: any RealtimeAIService {
        appModel.activeService
    }

    var body: some View {
        VStack(spacing: 10) {
            // 顶部状态栏
            HStack {
                // 状态指示点 + 文字
                HStack(spacing: 6) {
                    Text(service.connectionState == .connected ? "●" : "○")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(statusColor)
                        .opacity(service.connectionState == .connected && dotPulse ? 0.4 : 1.0)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                                   value: dotPulse)

                    Text(statusText)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(statusColor.opacity(0.9))
                }

                Spacer()

                // 服务商切换
                Picker("", selection: Binding(
                    get: { appModel.activeProvider },
                    set: { appModel.switchProvider(to: $0) }
                )) {
                    ForEach(AIProvider.allCases, id: \.self) { provider in
                        Text(provider.rawValue)
                            .font(.system(size: 11, design: .monospaced))
                            .tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .disabled(appModel.isGeminiActive)

                Spacer()

                // 会话倒计时
                if appModel.isGeminiActive {
                    Text(formattedRemainingTime)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(
                            service.sessionRemainingSeconds <= 30
                            ? Color.red : Color.hudCyan.opacity(0.7)
                        )
                }
            }
            .padding(.horizontal, 12)

            Divider()
                .background(Color.hudCyan.opacity(0.3))

            // 状态提示
            if appModel.isGeminiActive {
                if service.isModelSpeaking {
                    HStack(spacing: 6) {
                        Text("▶")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color.hudCyan)
                            .opacity(dotPulse ? 0.3 : 1.0)
                            .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true),
                                       value: dotPulse)
                        Text("AI RESPONDING...")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(Color.hudCyan)
                    }
                } else {
                    Text("VOICE ACTIVE // SPEAK NOW")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(Color.hudCyan.opacity(0.6))
                }
            } else {
                Text("INIT \(appModel.activeProvider.rawValue.uppercased()) MODULE TO BEGIN")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(Color.hudCyan.opacity(0.5))
            }

            Spacer()

            Divider()
                .background(Color.hudCyan.opacity(0.3))

            // 用户文字输入区域
            HStack(spacing: 8) {
                TextField("INPUT QUERY...", text: $appModel.userInputText)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(Color.hudCyan)
                    .textFieldStyle(.plain)
                    .padding(6)
                    .background(Color.black.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.hudCyan.opacity(0.4), lineWidth: 1)
                    )
                    .onSubmit {
                        appModel.sendUserQuestion(appModel.userInputText)
                    }
                    .disabled(!appModel.isGeminiActive
                              || service.connectionState != .connected)

                Button {
                    appModel.sendUserQuestion(appModel.userInputText)
                } label: {
                    Text("▶")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(Color.hudCyan)
                        .frame(width: 32, height: 28)
                        .background(Color.hudCyan.opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.hudCyan.opacity(0.5), lineWidth: 1)
                        )
                        .cornerRadius(3)
                }
                .disabled(appModel.userInputText.isEmpty
                          || !appModel.isGeminiActive
                          || service.connectionState != .connected)
            }
            .padding(.horizontal, 12)

            // 按钮区域
            HStack(spacing: 8) {
                Button {
                    appModel.toggleGeminiSession()
                } label: {
                    HStack {
                        Text(appModel.isGeminiActive ? "■ STOP" : "▶ START")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(appModel.isGeminiActive
                                ? Color.red.opacity(0.25)
                                : Color.hudCyan.opacity(0.15))
                    .foregroundColor(appModel.isGeminiActive ? Color.red : Color.hudCyan)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(appModel.isGeminiActive
                                    ? Color.red.opacity(0.7)
                                    : Color.hudCyan.opacity(0.6),
                                    lineWidth: 1)
                    )
                    .cornerRadius(3)
                }
                .buttonStyle(.plain)

                if showRetryButton {
                    Button {
                        appModel.stopGeminiSession()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            appModel.startGeminiSession()
                        }
                    } label: {
                        HStack {
                            Text("↺ RETRY")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.hudAmber.opacity(0.15))
                        .foregroundColor(Color.hudAmber)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.hudAmber.opacity(0.6), lineWidth: 1)
                        )
                        .cornerRadius(3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .padding(.vertical, 8)
        .frame(width: 960, height: 240)
        .background(Color.black.opacity(0.85))
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(Color.hudCyan.opacity(0.5), lineWidth: 1)
        )
        .onAppear {
            dotPulse = true
        }
    }

    // MARK: - Computed Properties

    private var showRetryButton: Bool {
        switch service.connectionState {
        case .error:
            return true
        case .disconnected:
            return service.sessionRemainingSeconds <= 0
        default:
            return false
        }
    }

    private var statusColor: Color {
        switch service.connectionState {
        case .connected:    return Color.hudCyan
        case .connecting:   return Color.hudAmber
        case .disconnected: return .gray
        case .error:        return .red
        }
    }

    private var statusText: String {
        switch service.connectionState {
        case .connected:    return "\(appModel.activeProvider.rawValue.uppercased()) // CONNECTED"
        case .connecting:   return "CONNECTING..."
        case .disconnected: return "OFFLINE"
        case .error(let msg):
            let short = String(msg.prefix(30))
            return "ERR: \(short)"
        }
    }

    private var formattedRemainingTime: String {
        let total   = service.sessionRemainingSeconds
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

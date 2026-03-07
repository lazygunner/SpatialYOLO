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
    @State private var spinAngle: Double = 0

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
            if appModel.isGeminiActive && service.connectionState == .connecting {
                // 连接中：旋转指示器
                HStack(spacing: 8) {
                    Circle()
                        .trim(from: 0.15, to: 0.85)
                        .stroke(Color.hudAmber, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 14, height: 14)
                        .rotationEffect(.degrees(spinAngle))
                        .onAppear {
                            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                                spinAngle = 360
                            }
                        }
                    Text(appModel.language == .english ? "ESTABLISHING CONNECTION..." : "正在建立连接...")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(Color.hudAmber)
                }
            } else if appModel.isGeminiActive {
                if service.isModelSpeaking {
                    HStack(spacing: 6) {
                        Text("▶")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color.hudCyan)
                            .opacity(dotPulse ? 0.3 : 1.0)
                            .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true),
                                       value: dotPulse)
                        Text(appModel.language == .english ? "AI RESPONDING..." : "AI 正在回复...")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(Color.hudCyan)
                    }
                } else {
                    Text(appModel.language == .english ? "VOICE ACTIVE // SPEAK NOW" : "语音服务已开启 // 请开始说话")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(Color.hudCyan.opacity(0.6))
                }
            } else {
                Text(appModel.language == .english ? "INIT \(appModel.activeProvider.rawValue.uppercased()) MODULE TO BEGIN" : "启动 \(appModel.activeProvider.rawValue.uppercased()) 模块开始体验")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(Color.hudCyan.opacity(0.5))
            }

            Divider()
                .background(Color.hudCyan.opacity(0.3))

            // 按钮区域
            HStack(spacing: 8) {

                Button {
                    appModel.toggleGeminiSession()
                } label: {
                    HStack(spacing: 8) {
                        if service.connectionState == .connecting {
                            // 连接中：旋转环 + CANCEL 提示
                            Circle()
                                .trim(from: 0.15, to: 0.85)
                                .stroke(Color.hudAmber, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .frame(width: 12, height: 12)
                                .rotationEffect(.degrees(spinAngle))
                            Text(appModel.language == .english ? "CONNECTING // TAP TO CANCEL" : "正在连接 // 点击取消")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                        } else {
                            Text(appModel.isGeminiActive 
                                 ? (appModel.language == .english ? "■ STOP" : "■ 停止") 
                                 : (appModel.language == .english ? "▶ START" : "▶ 启动"))
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(buttonBackground)
                    .foregroundColor(buttonForeground)
                    .cornerRadius(3)
                    .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 3))
                    .hoverEffect()
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
                            Text(appModel.language == .english ? "↺ RETRY" : "↺ 重试")
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
                        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 3))
                        .hoverEffect()
                    }
                    .buttonStyle(.plain)
                }

                // 自动解说开关 (Switch)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(appModel.language == .english ? "Auto mode" : "Auto 模式", isOn: $appModel.autoNarrate)
                        .toggleStyle(.switch)
                        .tint(.hudAmber)
                        .disabled(!appModel.isGeminiActive || service.connectionState != .connected)
                        .scaleEffect(0.8)
                        .frame(width: 140, alignment: .leading)
                        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 8))
                        .hoverEffect()
                    
                    Text(appModel.language == .english 
                         ? "Auto: Environment change detection / Manual: Manual question" 
                         : "Auto 模式自动检测环境变化 / Manual 模式需要人工询问")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.hudAmber.opacity(0.6))
                        .padding(.leading, 2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .padding(.vertical, 8)
        .frame(width: 960, height: 180)
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

    private var buttonBackground: Color {
        switch service.connectionState {
        case .connecting: return Color.hudAmber.opacity(0.12)
        default: return appModel.isGeminiActive ? Color.red.opacity(0.25) : Color.hudCyan.opacity(0.15)
        }
    }

    private var buttonForeground: Color {
        switch service.connectionState {
        case .connecting: return Color.hudAmber
        default: return appModel.isGeminiActive ? Color.red : Color.hudCyan
        }
    }

    private var buttonBorder: Color {
        switch service.connectionState {
        case .connecting: return Color.hudAmber.opacity(0.7)
        default: return appModel.isGeminiActive ? Color.red.opacity(0.7) : Color.hudCyan.opacity(0.6)
        }
    }

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
        case .connected:
            return appModel.language == .english 
                ? "\(appModel.activeProvider.rawValue.uppercased()) // CONNECTED"
                : "\(appModel.activeProvider.rawValue.uppercased()) // 已连接"
        case .connecting:
            return appModel.language == .english ? "CONNECTING..." : "正在建立连接..."
        case .disconnected:
            return appModel.language == .english ? "OFFLINE" : "断开连接"
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

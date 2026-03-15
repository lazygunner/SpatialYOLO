//
//  ContentView.swift
//  SpatialYOLO
//
//  Created by 关一鸣 on 2025/3/30.
//

import SwiftUI

struct ContentView: View {
    @Bindable var appModel: AppModel

    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题 + 语言切换
            HStack(alignment: .top) {
                Spacer()
                
                VStack(spacing: 6) {
                    Text("SpatialYOLO")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .purple, .pink],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )

                    Text(appModel.language == .english ? "Spatial Intelligence Platform" : "空间智能视觉平台")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.leading, 120) // 给右侧 Picker 留出平衡空间
                
                Spacer()
                
                // 语言切换器
                Picker("", selection: $appModel.language) {
                    ForEach(AppModel.AppLanguage.allCases) { lang in
                        Text(lang.rawValue).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .padding(.top, 10)
                .padding(.trailing, 20)
                .tint(.hudAmber)
            }
            .padding(.top, 24)
            .padding(.bottom, 20)

            // AI Live 卡片（支持 Gemini / Qwen）
            FeatureCard(
                icon: "sparkles",
                title: appModel.language == .english ? "Live AI Agent" : "Live AI Agent",
                subtitle: appModel.language == .english ? "Interactive Visual Assistant" : "交互式视觉助手",
                description: appModel.language == .english 
                    ? "Real-time visual + voice dialogue, saving daily memories" 
                    : "实时画面+语音双向对话，保存日常记忆",
                gradient: LinearGradient(
                    colors: [
                        Color.purple.opacity(0.6),
                        Color.pink.opacity(0.4)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                isActive: appModel.immersiveSpaceState == .open
                    && appModel.activeFeature == .geminiLive,
                isDisabled: appModel.immersiveSpaceState == .inTransition
            ) {
                await launchFeature(.geminiLive)
            }
            .padding(.horizontal, 30)

            Spacer().frame(height: 20)

            // 项目列表
            ProjectListView { session in
                openWindow(id: "projectDetail", value: session.id)
            }
            .padding(.horizontal, 10)

            Spacer()

            // 底部状态
            if appModel.immersiveSpaceState == .open {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text({
                        if appModel.language == .english {
                            switch appModel.activeFeature {
                            case .spatialYOLO: return "Spatial YOLO Running"
                            case .geminiLive: return "AI Live Running"
                            case .mahjong: return "Mahjong AI Running"
                            }
                        } else {
                            switch appModel.activeFeature {
                            case .spatialYOLO: return "Spatial YOLO 运行中"
                            case .geminiLive: return "AI Live 运行中"
                            case .mahjong: return "Mahjong AI 运行中"
                            }
                        }
                    }())
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 16)
            }
        }
        .frame(width: 880, height: 500)
        .task {
            appModel.requestLocalNetworkPermissionIfNeeded()
            await CloudMemorySyncService.shared.syncCompletedSessionsIfNeeded()
        }
    }

    // MARK: - 启动/切换功能

    private func launchFeature(_ mode: AppModel.FeatureMode) async {
        // 如果当前功能正在运行，点击则关闭
        if appModel.immersiveSpaceState == .open && appModel.activeFeature == mode {
            appModel.immersiveSpaceState = .inTransition
            await dismissImmersiveSpace()
            return
        }

        // 如果另一个功能在运行，先关闭
        if appModel.immersiveSpaceState == .open {
            appModel.immersiveSpaceState = .inTransition
            await dismissImmersiveSpace()
            // 等待关闭完成
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // 设置新功能模式并启动
        appModel.activeFeature = mode
        appModel.immersiveSpaceState = .inTransition

        switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
        case .opened:
            dismissWindow(id: "main")
        case .userCancelled, .error:
            fallthrough
        @unknown default:
            appModel.immersiveSpaceState = .closed
        }
    }
}

// MARK: - 功能卡片组件

struct FeatureCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let description: String
    let gradient: LinearGradient
    let isActive: Bool
    let isDisabled: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                // 图标 + 状态
                HStack {
                    ZStack {
                        Circle()
                            .fill(gradient)
                            .frame(width: 48, height: 48)

                        Image(systemName: icon)
                            .font(.system(size: 22))
                            .foregroundColor(.white)
                    }

                    Spacer()

                    if isActive {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.green)
                                .frame(width: 6, height: 6)
                            Text("运行中")
                                .font(.caption2)
                                .foregroundColor(.green)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.green.opacity(0.15))
                        .clipShape(Capsule())
                    }
                }

                // 标题
                Text(title)
                    .font(.title3.bold())
                    .foregroundColor(.white)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(gradient)

                // 描述
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

            }
            .padding(20)
            .background(
                ZStack {
                    // 渐变底色
                    RoundedRectangle(cornerRadius: 20)
                        .fill(gradient.opacity(isActive ? 0.3 : 0.15))

                    // 边框高光
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(
                            isActive
                                ? gradient
                                : LinearGradient(
                                    colors: [.white.opacity(0.2), .clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                            lineWidth: isActive ? 2 : 1
                        )
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .glassBackgroundEffect()
        }
        .frame(width: 800, height: 180)
        .buttonStyle(.plain)
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 20))
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
    }
}

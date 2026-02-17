//
//  ContentView.swift
//  SpatialYOLO
//
//  Created by 关一鸣 on 2025/3/30.
//

import SwiftUI

struct ContentView: View {
    var appModel: AppModel

    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题
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

                Text("空间智能视觉平台")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 30)
            .padding(.bottom, 24)

            // 功能卡片区域
            HStack(spacing: 20) {
                // YOLO 双目检测卡片
                FeatureCard(
                    icon: "eye.trianglebadge.exclamationmark",
                    title: "Spatial YOLO",
                    subtitle: "双目物体检测 + 深度估计",
                    description: "使用 YOLOv11 进行实时物体检测，双目立体视觉生成深度图",
                    gradient: LinearGradient(
                        colors: [
                            Color.blue.opacity(0.6),
                            Color.cyan.opacity(0.4)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    isActive: appModel.immersiveSpaceState == .open
                        && appModel.activeFeature == .spatialYOLO,
                    isDisabled: appModel.immersiveSpaceState == .inTransition
                ) {
                    await launchFeature(.spatialYOLO)
                }

                // AI Live 卡片（支持 Gemini / Qwen）
                FeatureCard(
                    icon: "sparkles",
                    title: "AI Live",
                    subtitle: "交互式视觉助手",
                    description: "实时画面+语音双向对话，支持 Gemini / Qwen 切换",
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
            }
            .padding(.horizontal, 30)

            Spacer()

            // 底部状态
            if appModel.immersiveSpaceState == .open {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text(appModel.activeFeature == .spatialYOLO
                         ? "Spatial YOLO 运行中" : "AI Live 运行中")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 20)
            }
        }
        .frame(width: 620, height: 420)
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

                Spacer(minLength: 0)

                // 底部按钮提示
                HStack {
                    Spacer()
                    Text(isActive ? "点击退出" : "点击启动")
                        .font(.caption.bold())
                        .foregroundColor(isActive ? .red.opacity(0.8) : .white.opacity(0.8))
                    Image(systemName: isActive ? "stop.circle" : "arrow.right.circle.fill")
                        .foregroundColor(isActive ? .red.opacity(0.8) : .white.opacity(0.8))
                }
            }
            .padding(20)
            .frame(width: 260, height: 280)
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
            .glassBackgroundEffect()
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
    }
}

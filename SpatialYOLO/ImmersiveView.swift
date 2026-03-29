//
//  ImmersiveView.swift
//  SpatialYOLO
//
//  Created by 关一鸣 on 2025/3/30.
//

import SwiftUI
import RealityKit
import RealityKitContent
import ARKit

struct ImmersiveView: View {
    var appModel: AppModel
    @State private var leftCameraEntity: Entity?
    @State private var rightCameraEntity: Entity?
    @State private var depthEntity: Entity?
    @State private var geminiBoundingBoxEntity: Entity?
    @State private var translationSubtitleEntity: Entity?
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RealityView { content, attachments in

            let anchor = AnchorEntity(.head)

            switch appModel.activeFeature {
            case .spatialYOLO:
                setupSpatialYOLO(anchor: anchor, attachments: attachments)
            case .geminiLive:
                setupGeminiLive(anchor: anchor, attachments: attachments)
            }

            content.add(anchor)

        } attachments: {
            // Spatial YOLO 附件
            Attachment(id: "leftCameraView") {
                DualCameraView(model: appModel, isLeft: true)
            }

            Attachment(id: "depthView") {
                DepthView(model: appModel)
            }

            Attachment(id: "rightCameraView") {
                VStack {
                    DualCameraView(model: appModel, isLeft: false)
                    exitButton
                }
            }

            // Gemini Live 附件：JARVIS HUD + 音频监测 + 控制面板
            Attachment(id: "geminiBoundingBox") {
                VStack(spacing: 6) {
                    // JARVIS HUD 覆盖层（相机画面 + 检测框 + 人脸卡 + telemetry）
                    AILiveHUDView(model: appModel)

                    // 环境语音监听：波形 + 本地 STT（独立开关）
                    AudioMonitorView(
                        monitor: appModel.audioInputMonitor,
                        language: appModel.language,
                        historyEntries: appModel.audioTranscriptHistory
                    )
                        .frame(width: 960)

                    // 控制面板（HUD 风格）
                    GeminiResponseView(appModel: appModel)

                    exitButton
                }
            }

            // 语音转写字幕：独立悬浮在用户正前方偏下
            Attachment(id: "translationSubtitle") {
                TranslationSubtitleOverlay(geminiService: appModel.activeService)
            }

        }
        .task {
            appModel.setupVision()
            await appModel.startSession()
            if appModel.activeFeature == .geminiLive {
                appModel.audioInputMonitor.scheduleAutoStart(after: 1.2)
            }
        }
        .onDisappear {
            if appModel.activeFeature == .geminiLive {
                appModel.audioInputMonitor.cancelScheduledAutoStart()
                appModel.audioInputMonitor.stopIfNeeded()
            }
        }
    }

    // MARK: - Spatial YOLO 布局

    private func setupSpatialYOLO(anchor: AnchorEntity, attachments: RealityViewAttachments) {
        // 左摄像头（左侧）
        if let attachment = attachments.entity(for: "leftCameraView") {
            leftCameraEntity = attachment
            attachment.position = SIMD3<Float>(-0.35, 0.0, -0.5)
            attachment.transform.rotation = simd_quatf(angle: .pi / 12, axis: [0, 1, 0])
            attachment.transform.scale = [0.4, 0.4, 0.4]
            anchor.addChild(attachment)
        }

        // 深度图（中央）
        if let attachment = attachments.entity(for: "depthView") {
            depthEntity = attachment
            attachment.position = SIMD3<Float>(0.0, 0.0, -0.5)
            attachment.transform.scale = [0.4, 0.4, 0.4]
            anchor.addChild(attachment)
        }

        // 右摄像头（右侧）
        if let attachment = attachments.entity(for: "rightCameraView") {
            rightCameraEntity = attachment
            attachment.position = SIMD3<Float>(0.35, 0.0, -0.5)
            attachment.transform.rotation = simd_quatf(angle: -.pi / 12, axis: [0, 1, 0])
            attachment.transform.scale = [0.4, 0.4, 0.4]
            anchor.addChild(attachment)
        }
    }

    // MARK: - Gemini Live 布局

    private func setupGeminiLive(anchor: AnchorEntity, attachments: RealityViewAttachments) {
        // HUD 控制面板：稍偏左，轻微旋转，视线余光可见
        if let attachment = attachments.entity(for: "geminiBoundingBox") {
            geminiBoundingBoxEntity = attachment
            attachment.position = SIMD3<Float>(-0.2, -0.05, -0.5)
            attachment.transform.rotation = simd_quatf(angle: .pi / 8, axis: [0, 1, 0])
            attachment.transform.scale = [0.4, 0.4, 0.4]
            anchor.addChild(attachment)
        }

        // 语音转写字幕：正前方居中、视野偏下，独立悬浮
        if let attachment = attachments.entity(for: "translationSubtitle") {
            translationSubtitleEntity = attachment
            attachment.position = SIMD3<Float>(0, -0.22, -0.65)
            attachment.transform.scale = [0.45, 0.45, 0.45]
            anchor.addChild(attachment)
        }
    }

    // MARK: - 退出按钮

    private var exitButton: some View {
        ToggleImmersiveSpaceButton(appModel: appModel)
    }
}

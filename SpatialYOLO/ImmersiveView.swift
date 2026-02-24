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
    @State private var mahjongEntity: Entity?
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
            case .mahjong:
                setupMahjong(anchor: anchor, attachments: attachments)
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

            // 麻将检测附件：牌型栏（常驻）+ 可折叠区域
            Attachment(id: "mahjongView") {
                VStack(spacing: 6) {
                    // 牌型展示 + 分析按钮 + 收起/展开按钮（始终可见）
                    MahjongTileBar(model: appModel)

                    // 可折叠区域：摄像头 + 打牌记录 + 分析结果 + 语音控制面板
                    if appModel.mahjongPanelExpanded {
                        ZStack(alignment: .bottom) {
                            MahjongDetectionView(model: appModel)

                            // Omni 语音监听字幕（打牌事件识别）
                            GeminiSubtitleOverlay(geminiService: appModel.activeService)
                        }

                        // 其他玩家打牌记录
                        MahjongDiscardRecordView(model: appModel)

                        // AI 语音控制面板（Omni 连接/断开）
                        GeminiResponseView(appModel: appModel)
                    }

                    exitButton
                }
            }

            // Gemini Live 附件：JARVIS HUD + 字幕叠加 + 控制面板
            Attachment(id: "geminiBoundingBox") {
                VStack(spacing: 8) {
                    ZStack(alignment: .bottom) {
                        // JARVIS HUD 覆盖层（自带相机画面 + 检测框 + 人脸卡 + telemetry）
                        AILiveHUDView(model: appModel)

                        // AI 回复字幕（打字机效果，底部 20% 区域）
                        GeminiSubtitleOverlay(geminiService: appModel.activeService)
                    }

                    // 控制面板（HUD 风格）
                    GeminiResponseView(appModel: appModel)

                    exitButton
                }
            }
        }
        .task {
            appModel.setupVision()
            await appModel.startSession()
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
        // 摄像头画面 + 字幕 + 控制面板（居中）
        if let attachment = attachments.entity(for: "geminiBoundingBox") {
            geminiBoundingBoxEntity = attachment
            attachment.position = SIMD3<Float>(-0.2, -0.05, -0.5)
            attachment.transform.rotation = simd_quatf(angle: .pi / 8, axis: [0, 1, 0])
            attachment.transform.scale = [0.4, 0.4, 0.4]
            anchor.addChild(attachment)
        }
    }

    // MARK: - 麻将检测布局

    private func setupMahjong(anchor: AnchorEntity, attachments: RealityViewAttachments) {
        // 摄像头 + 牌型栏 + 控制面板（正前方居中，无旋转）
        if let attachment = attachments.entity(for: "mahjongView") {
            mahjongEntity = attachment
            attachment.position = SIMD3<Float>(0, 0.0, -0.6)
            attachment.transform.rotation = simd_quatf(angle: 0, axis: [0, 1, 0])
            attachment.transform.scale = [0.4, 0.4, 0.4]
            anchor.addChild(attachment)
        }
    }

    // MARK: - 退出按钮

    private var exitButton: some View {
        ToggleImmersiveSpaceButton(appModel: appModel)
    }
}

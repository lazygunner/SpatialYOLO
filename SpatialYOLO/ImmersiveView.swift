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
    @State private var geminiEntity: Entity?
    @State private var geminiBoundingBoxEntity: Entity?
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

            // Gemini Live 附件
            Attachment(id: "geminiBoundingBox") {
                VStack {
                    DualCameraView(model: appModel, isLeft: true)
                    exitButton
                }
            }

            Attachment(id: "geminiResponse") {
                GeminiResponseView(appModel: appModel)
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
        // 摄像头画面 + 边界框（左侧）
        if let attachment = attachments.entity(for: "geminiBoundingBox") {
            geminiBoundingBoxEntity = attachment
            attachment.position = SIMD3<Float>(-0.15, -0.05, -0.5)
            attachment.transform.rotation = simd_quatf(angle: .pi / 15, axis: [0, 1, 0])
            attachment.transform.scale = [0.4, 0.4, 0.4]
            anchor.addChild(attachment)
        }

        // Gemini 响应面板（右侧）
        if let attachment = attachments.entity(for: "geminiResponse") {
            geminiEntity = attachment
            attachment.position = SIMD3<Float>(0.2, -0.05, -0.5)
            attachment.transform.rotation = simd_quatf(angle: -.pi / 15, axis: [0, 1, 0])
            attachment.transform.scale = [0.4, 0.4, 0.4]
            anchor.addChild(attachment)
        }
    }

    // MARK: - 退出按钮

    private var exitButton: some View {
        ToggleImmersiveSpaceButton(appModel: appModel)
    }
}

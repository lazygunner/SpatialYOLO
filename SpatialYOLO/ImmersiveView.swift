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
    let boundingBoxes: [CGRect] = [CGRect()]
    @State private var cameraEntity: Entity?
    @Environment(\.dismissWindow) private var dismissWindow
    
    var body: some View {
        RealityView { content, attachments in
            
            // 将 Attachment 添加到平面实体上
            if let cameraAttachment = attachments.entity(for: "cameraView") {
                content.add(cameraAttachment)
                cameraEntity = cameraAttachment
            }
            let anchor = AnchorEntity(.head)
            anchor.addChild(cameraEntity!)
            cameraEntity?.position.z = -0.5
            cameraEntity?.position.x = -0.1
            cameraEntity?.position.y = -0.1
            // 沿着Y轴旋转30度
            cameraEntity?.transform.rotation = simd_quatf(angle: .pi / 12, axis: [0, 1, 0])
            cameraEntity?.transform.scale = [0.5, 0.5, 0.5]
            content.add(anchor)
            
        } attachments: {
            Attachment(id: "cameraView", {
                VStack {
                    BoundingBoxOverlay(model: appModel)
                    
                    ToggleImmersiveSpaceButton(appModel: appModel)

                }
            })
        }
        .task {
            appModel.setupVision()
            await appModel.startSession()
        }
    }
}

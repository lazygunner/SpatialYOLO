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
    @State private var leftCameraEntity: Entity?
    @State private var rightCameraEntity: Entity?
    @Environment(\.dismissWindow) private var dismissWindow
    
    var body: some View {
        RealityView { content, attachments in
            
            // 添加左摄像头 Attachment
            if let leftCameraAttachment = attachments.entity(for: "leftCameraView") {
                content.add(leftCameraAttachment)
                leftCameraEntity = leftCameraAttachment
            }
            
            // 添加右摄像头 Attachment
            if let rightCameraAttachment = attachments.entity(for: "rightCameraView") {
                content.add(rightCameraAttachment)
                rightCameraEntity = rightCameraAttachment
            }
            
            let anchor = AnchorEntity(.head)
            
            // 设置左摄像头位置（左侧）
            if let leftEntity = leftCameraEntity {
                anchor.addChild(leftEntity)
                leftEntity.position.z = -0.5
                leftEntity.position.x = -0.2  // 左侧
                leftEntity.position.y = 0.0
                leftEntity.transform.rotation = simd_quatf(angle: .pi / 12, axis: [0, 1, 0])
                leftEntity.transform.scale = [0.5, 0.5, 0.5]
            }
            
            // 设置右摄像头位置（右侧）
            if let rightEntity = rightCameraEntity {
                anchor.addChild(rightEntity)
                rightEntity.position.z = -0.5
                rightEntity.position.x = 0.2   // 右侧
                rightEntity.position.y = 0.0
                rightEntity.transform.rotation = simd_quatf(angle: -.pi / 12, axis: [0, 1, 0])
                rightEntity.transform.scale = [0.5, 0.5, 0.5]
            }
            
            content.add(anchor)
            
        } attachments: {
            // 左摄像头附件
            Attachment(id: "leftCameraView", {
                VStack {
                    DualCameraView(model: appModel, isLeft: true)
                }
            })
            
            // 右摄像头附件
            Attachment(id: "rightCameraView", {
                VStack {
                    DualCameraView(model: appModel, isLeft: false)
                    
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

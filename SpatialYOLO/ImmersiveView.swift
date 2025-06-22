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
    @State private var depthEntity: Entity?
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
            
            // 添加深度图 Attachment
            if let depthAttachment = attachments.entity(for: "depthView") {
                content.add(depthAttachment)
                depthEntity = depthAttachment
            }
            
            let anchor = AnchorEntity(.head)
            
            // 设置左摄像头位置（左侧）
            if let leftEntity = leftCameraEntity {
                anchor.addChild(leftEntity)
                leftEntity.position.z = -0.5
                leftEntity.position.x = -0.35  // 更向左一些，为深度图留出空间
                leftEntity.position.y = 0.0
                leftEntity.transform.rotation = simd_quatf(angle: .pi / 12, axis: [0, 1, 0])
                leftEntity.transform.scale = [0.4, 0.4, 0.4]  // 稍微缩小
            }
            
            // 设置深度图位置（中央）
            if let depthEnt = depthEntity {
                anchor.addChild(depthEnt)
                depthEnt.position.z = -0.5
                depthEnt.position.x = 0.0   // 中央
                depthEnt.position.y = 0.0
                depthEnt.transform.scale = [0.4, 0.4, 0.4]
            }
            
            // 设置右摄像头位置（右侧）
            if let rightEntity = rightCameraEntity {
                anchor.addChild(rightEntity)
                rightEntity.position.z = -0.5
                rightEntity.position.x = 0.35   // 更向右一些，为深度图留出空间
                rightEntity.position.y = 0.0
                rightEntity.transform.rotation = simd_quatf(angle: -.pi / 12, axis: [0, 1, 0])
                rightEntity.transform.scale = [0.4, 0.4, 0.4]  // 稍微缩小
            }
            
            content.add(anchor)
            
        } attachments: {
            // 左摄像头附件
            Attachment(id: "leftCameraView", {
                VStack {
                    DualCameraView(model: appModel, isLeft: true)
                }
            })
            
            // 深度图附件
            Attachment(id: "depthView", {
                VStack {
                    DepthView(model: appModel)
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

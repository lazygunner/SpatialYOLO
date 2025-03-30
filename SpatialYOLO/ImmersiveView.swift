//
//  ImmersiveView.swift
//  SpatialYOLO
//
//  Created by 关一鸣 on 2025/3/30.
//

import SwiftUI
import RealityKit
import RealityKitContent

struct ImmersiveView: View {
    var appModel: AppModel
    let boundingBoxes: [CGRect] = [CGRect()]
    // timer one second

    var body: some View {
        RealityView { content, attachments in

        } attachments: {

        }
        .task {
            appModel.setupVision()
            await appModel.startSession()
        }
    }
}

//
//  ContentView.swift
//  SpatialYOLO
//
//  Created by 关一鸣 on 2025/3/30.
//

import SwiftUI
import RealityKit
import RealityKitContent

struct ContentView: View {
    var appModel: AppModel

    var body: some View {
        VStack {
            Model3D(named: "Scene", bundle: realityKitContentBundle)
                .padding(.bottom, 50)

            Text("Hello, world!")

            ToggleImmersiveSpaceButton(appModel: appModel)
        }
        .padding()
    }
}

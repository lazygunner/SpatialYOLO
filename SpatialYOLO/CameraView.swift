//
//  CameraView.swift
//  SpatialYOLO
//
//  Created by 关一鸣 on 2025/3/30.
//

import SwiftUI
import RealityKit

struct BoundingBoxOverlay: View {
    let model: AppModel
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                //宽度 960的正方形
                Rectangle()
                    .path(in: CGRect(origin: CGPoint(x: 0, y: 0), size: CGSize(width: geometry.size.width, height: geometry.size.height)))
                    .stroke(Color.purple, lineWidth: 2)
            }
            
            ZStack {
                Image(uiImage: model.capturedImage ?? UIImage())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 960, height: 540)
                
                // 宽度540的正方形
                Rectangle()
                    .path(in: CGRect(origin: CGPoint(x: Double(geometry.size.width - geometry.size.height) / 2, y: 0), size: CGSize(width: geometry.size.height, height: geometry.size.height)))
                    .stroke(Color.green, lineWidth: 1)
                                    
                ForEach(0..<model.boundingBoxes.count, id: \.self) { index in
                    let box = model.boundingBoxes[index]
                    let confidence = model.confidences[index]
                    let className = model.detectedClasses[index]
                    
                    // 根据className生成固定的随机颜色
                    let color = Color(hue: Double(className.hashValue % 360) / 360.0,
                                   saturation: 0.8,
                                   brightness: 0.8)
                    
                    let scaledBoxCenterCrop = CGRect(
                        x: box.origin.x * geometry.size.width,
                        y: geometry.size.height - box.origin.y * geometry.size.height - box.size.height * geometry.size.height,
                        width: box.size.width * geometry.size.width,
                        height: box.size.height * geometry.size.height
                    )
                    
                    ZStack(alignment: .leading, spacing: 0) {
                        Rectangle()
                            .path(in: scaledBoxCenterCrop)
                            .stroke(color, lineWidth: 2)
                        
                        Text("\(className) (\(Int(confidence))%)")
                            .font(.caption)
                            .foregroundColor(color)
                            .background(Color.black.opacity(0.5))
                            .padding(2)
                            .position(x: scaledBoxCenterCrop.maxX - 5, y: scaledBoxCenterCrop.maxY - 5)
                    }
                }
            }
        }
        .frame(width: 960, height: 540)
        .glassBackgroundEffect()
    }
}

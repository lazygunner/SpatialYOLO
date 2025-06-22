//
//  CameraView.swift
//  SpatialYOLO
//
//  Created by 关一鸣 on 2025/3/30.
//

import SwiftUI
import RealityKit

// 新的组件，支持显示指定的摄像头（左或右）
struct DualCameraView: View {
    let model: AppModel
    let isLeft: Bool // true 为左摄像头，false 为右摄像头
    let title: String
    
    init(model: AppModel, isLeft: Bool) {
        self.model = model
        self.isLeft = isLeft
        self.title = isLeft ? "Left Camera" : "Right Camera"
    }
    
    private var capturedImage: UIImage? {
        isLeft ? model.capturedImageLeft : model.capturedImageRight
    }
    
    private var boundingBoxes: [CGRect] {
        isLeft ? model.boundingBoxesLeft : model.boundingBoxesRight
    }
    
    private var detectedClasses: [String] {
        isLeft ? model.detectedClassesLeft : model.detectedClassesRight
    }
    
    private var confidences: [Float] {
        isLeft ? model.confidencesLeft : model.confidencesRight
    }
    
    var body: some View {
        VStack(spacing: 5) {
            
            GeometryReader { geometry in
                ZStack {
                    // 外边框
                    Rectangle()
                        .path(in: CGRect(origin: CGPoint(x: 0, y: 0), size: CGSize(width: geometry.size.width, height: geometry.size.height)))
                        .stroke(isLeft ? Color.blue : Color.orange, lineWidth: 2)
                }
                
                ZStack {
                    Image(uiImage: capturedImage ?? UIImage())
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    
                    // 内边框
                    Rectangle()
                        .path(in: CGRect(origin: CGPoint(x: Double(geometry.size.width - geometry.size.height) / 2, y: 0), size: CGSize(width: geometry.size.height, height: geometry.size.height)))
                        .stroke(Color.green, lineWidth: 1)
                                        
                    ForEach(0..<boundingBoxes.count, id: \.self) { index in
                        let box = boundingBoxes[index]
                        let confidence = confidences[index]
                        let className = detectedClasses[index]
                        
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
        }
        .frame(width: 960, height: 540) // 稍微小一点的尺寸
        .glassBackgroundEffect()
    }
}

// 新增的深度图显示组件
struct DepthView: View {
    let model: AppModel
    
    var body: some View {
        VStack(spacing: 5) {
            Text("深度图")
                .font(.headline)
                .foregroundColor(.white)
            
            GeometryReader { geometry in
                ZStack {
                    // 外边框
                    Rectangle()
                        .path(in: CGRect(origin: CGPoint(x: 0, y: 0), size: CGSize(width: geometry.size.width, height: geometry.size.height)))
                        .stroke(Color.purple, lineWidth: 2)
                    
                    // 深度图显示
                    Image(uiImage: model.depthImage ?? UIImage())
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .overlay(
                            // 如果没有深度图，显示占位符
                            Group {
                                if model.depthImage == nil {
                                    VStack {
                                        Image(systemName: "cube.transparent")
                                            .font(.system(size: 50))
                                            .foregroundColor(.gray)
                                        Text("处理深度图中...")
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                    }
                                }
                            }
                        )
                }
            }
        }
        .frame(width: 960, height: 540)
        .glassBackgroundEffect()
    }
}

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

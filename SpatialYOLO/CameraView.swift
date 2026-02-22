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

    private var objectDepths: [Float?] {
        isLeft ? model.objectDepths : []
    }

    private var objectDistanceMeters: [Float?] {
        isLeft ? model.objectDistanceMeters : []
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

                        // 距离标签（仅左摄像头有深度数据）
                        let distLabel: String = {
                            // 优先显示实际距离（米）
                            if index < objectDistanceMeters.count,
                               let m = objectDistanceMeters[index] {
                                return String(format: " · %d cm", Int(m * 100))
                            }
                            // 回退：相对标签
                            guard index < objectDepths.count, let d = objectDepths[index] else { return "" }
                            if d < 0.33 { return " · 近" }
                            else if d < 0.66 { return " · 中" }
                            else { return " · 远" }
                        }()

                        ZStack(alignment: .leading, spacing: 0) {
                            Rectangle()
                                .path(in: scaledBoxCenterCrop)
                                .stroke(color, lineWidth: 2)

                            Text("\(className) (\(Int(confidence))%)\(distLabel)")
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
            // 标题行 + 双目/单目切换
            HStack {
                Text("深度图")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Picker("", selection: Binding<AppModel.DepthSource>(
                    get: { model.depthSource },
                    set: { model.depthSource = $0 }
                )) {
                    Text("双目").tag(AppModel.DepthSource.stereo)
                    Text("单目").tag(AppModel.DepthSource.monocular)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }
            .padding(.horizontal, 8)
            
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

// 麻将牌检测视图
struct MahjongDetectionView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geometry in
                ZStack {
                    // 外边框（麻将桌绿色）
                    Rectangle()
                        .path(in: CGRect(origin: .zero, size: geometry.size))
                        .stroke(Color.green, lineWidth: 2)
                }

                ZStack {
                    Image(uiImage: model.capturedImageLeft ?? UIImage())
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)

                    ForEach(model.mahjongDetections) { tile in
                        let scaledBox = CGRect(
                            x: tile.box.origin.x * geometry.size.width,
                            y: geometry.size.height - tile.box.origin.y * geometry.size.height - tile.box.size.height * geometry.size.height,
                            width: tile.box.size.width * geometry.size.width,
                            height: tile.box.size.height * geometry.size.height
                        )

                        ZStack(alignment: .leading, spacing: 0) {
                            Rectangle()
                                .path(in: scaledBox)
                                .stroke(Color.green, lineWidth: 2)

                            Text("\(tile.className) \(Int(tile.confidence))%")
                                .font(.caption.bold())
                                .foregroundColor(.yellow)
                                .background(Color.black.opacity(0.6))
                                .padding(2)
                                .position(x: scaledBox.midX, y: scaledBox.minY - 10)
                        }
                    }
                }
            }
        }
        .frame(width: 960, height: 540)
        .glassBackgroundEffect()
    }
}

// 麻将牌型展示栏 + 牌局控制 + 分析按钮
struct MahjongTileBar: View {
    let model: AppModel

    /// 展示用牌型：牌局中用记忆手牌，否则用当前帧检测
    private var displayCodes: [String] {
        if model.mahjongGameActive && !model.mahjongHandMemory.isEmpty {
            return model.mahjongHandMemory
        }
        return model.mahjongDetections.map { $0.classCode }
    }

    var body: some View {
        VStack(spacing: 6) {
            // 顶部：牌局状态 + 控制按钮
            HStack(spacing: 8) {
                // 牌局状态（含超限警告）
                let count = displayCodes.count
                let maxCount = model.mahjongMaxHandTiles
                let overLimit = count > maxCount
                HStack(spacing: 4) {
                    Circle()
                        .fill(model.mahjongGameActive ? (overLimit ? Color.red : Color.green) : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(model.mahjongGameActive
                         ? "\(count)/\(maxCount)张\(overLimit ? " ⚠️" : "")"
                         : "未开局")
                        .font(.caption)
                        .foregroundColor(overLimit ? .red : .secondary)
                }

                // 手牌状态切换（摸牌13张 / 打牌14张）
                if model.mahjongGameActive {
                    Button {
                        model.mahjongHandState = model.mahjongHandState == .waitingToDiscard
                            ? .waitingToDraw : .waitingToDiscard
                    } label: {
                        Text(model.mahjongHandState == .waitingToDiscard ? "待打牌" : "待摸牌")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(model.mahjongHandState == .waitingToDiscard ? .orange : .cyan)
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                // 牌局控制按钮
                if model.mahjongGameActive {
                    Button {
                        model.resetMahjongGame()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("重置")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                } else {
                    Button {
                        model.startMahjongGame()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "play.fill")
                            Text("开始牌局")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                    .disabled(model.mahjongDetections.isEmpty)
                }

                // 分析按钮（使用独立 LLM，不依赖 Omni 连接状态）
                Button {
                    model.sendMahjongAnalysis()
                } label: {
                    HStack(spacing: 4) {
                        if model.mahjongAnalysisService.isAnalyzing {
                            ProgressView()
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(model.mahjongAnalysisService.isAnalyzing ? "分析中..." : "分析牌型")
                    }
                    .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(displayCodes.isEmpty || model.mahjongAnalysisService.isAnalyzing)

                // 收起 / 展开控制面板按钮
                Button {
                    model.mahjongPanelExpanded.toggle()
                } label: {
                    Image(systemName: model.mahjongPanelExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.bold())
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }
            .padding(.horizontal, 12)

            // 底部：手牌展示
            HStack(spacing: 4) {
                Text("手牌")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 30)

                if displayCodes.isEmpty {
                    Text("等待识别...")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .italic()
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 3) {
                            ForEach(Array(displayCodes.enumerated()), id: \.offset) { _, code in
                                let name = AppModel.mahjongClassNames[code] ?? code
                                let emoji = AppModel.mahjongTileEmojis[code] ?? ""

                                VStack(spacing: 1) {
                                    Text(emoji)
                                        .font(.system(size: 26))
                                    Text(name)
                                        .font(.system(size: 8))
                                        .foregroundColor(.white)
                                }
                                .frame(width: 36, height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(tileColor(for: code).opacity(0.3))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(tileColor(for: code), lineWidth: 1)
                                )
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
            }
            .padding(.horizontal, 12)

            // AI 分析结果（内嵌在牌型栏底部）
            if model.mahjongAnalysisService.isAnalyzing || !model.mahjongAnalysisService.analysisResult.isEmpty {
                Divider()
                    .padding(.horizontal, 12)

                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.caption)
                        .foregroundColor(.purple)
                    Text("AI 分析")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                    if model.mahjongAnalysisService.isAnalyzing {
                        ProgressView()
                            .scaleEffect(0.5)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)

                if model.mahjongAnalysisService.analysisResult.isEmpty {
                    Text("思考中...")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .italic()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(model.mahjongAnalysisService.analysisResult)
                            .font(.system(size: 13))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                    }
                    .frame(maxHeight: 150)
                }
            }
        }
        .padding(.vertical, 8)
        .frame(width: 960)
        .glassBackgroundEffect()
    }

    /// 按花色返回主题色
    private func tileColor(for code: String) -> Color {
        if code == "RD" { return .red }               // 红中
        if code == "GD" { return .green }             // 发财
        if code == "WD" { return .white }             // 白板
        if ["EW", "SW", "WW", "NW"].contains(code) { return .cyan } // 风 - 青色
        if code.hasSuffix("C") { return .red }        // 万 - 红色
        if code.hasSuffix("B") { return .green }      // 条 - 绿色
        if code.hasSuffix("D") { return .blue }       // 筒 - 蓝色
        return .yellow                                 // 花牌
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

                    // 距离标签
                    let distLabel: String = {
                        if index < model.objectDistanceMeters.count,
                           let m = model.objectDistanceMeters[index] {
                            return String(format: " · %d cm", Int(m * 100))
                        }
                        guard index < model.objectDepths.count, let d = model.objectDepths[index] else { return "" }
                        if d < 0.33 { return " · 近" }
                        else if d < 0.66 { return " · 中" }
                        else { return " · 远" }
                    }()

                    ZStack(alignment: .leading, spacing: 0) {
                        Rectangle()
                            .path(in: scaledBoxCenterCrop)
                            .stroke(color, lineWidth: 2)

                        Text("\(className) (\(Int(confidence))%)\(distLabel)")
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

// MARK: - 打牌记录视图（其他玩家出牌）

struct MahjongDiscardRecordView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "person.3.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                Text("打牌记录")
                    .font(.caption.bold())
                    .foregroundColor(.white)

                Spacer()

                if !model.discardRecords.isEmpty {
                    Button {
                        model.clearDiscardRecords()
                    } label: {
                        Text("清空")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
            .padding(.horizontal, 12)

            if model.discardRecords.isEmpty {
                Text("等待语音监听...")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .italic()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(model.discardRecords) { record in
                            VStack(alignment: .leading, spacing: 2) {
                                // 玩家标签
                                Text(record.player)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.cyan)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.cyan.opacity(0.2))
                                    .cornerRadius(4)

                                // 出牌记录（最新 6 条，最新在上）
                                ForEach(record.events.suffix(6).reversed()) { event in
                                    HStack(spacing: 2) {
                                        Text(event.action)
                                            .font(.system(size: 9))
                                            .foregroundColor(actionColor(event.action))
                                        if !event.tile.isEmpty {
                                            Text(event.tile)
                                                .font(.system(size: 9, weight: .medium))
                                                .foregroundColor(.white)
                                        }
                                    }
                                }
                            }
                            .frame(minWidth: 60)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: 960, height: 80)
        .glassBackgroundEffect()
    }

    private func actionColor(_ action: String) -> Color {
        switch action {
        case "打": return .white
        case "碰": return .yellow
        case "杠": return .orange
        case "吃": return .green
        case "胡": return .red
        default: return .gray
        }
    }
}

// MARK: - 牌型分析结果视图

struct MahjongAnalysisView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "brain.head.profile")
                    .font(.caption)
                    .foregroundColor(.purple)
                Text("AI 牌型分析")
                    .font(.caption.bold())
                    .foregroundColor(.white)

                if model.mahjongAnalysisService.isAnalyzing {
                    ProgressView()
                        .scaleEffect(0.5)
                }

                Spacer()
            }
            .padding(.horizontal, 12)

            if model.mahjongAnalysisService.analysisResult.isEmpty {
                Text("点击「分析牌型」获取 AI 建议")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .italic()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(model.mahjongAnalysisService.analysisResult)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
                .frame(maxHeight: 400)
            }
        }
        .padding(.vertical, 4)
        .frame(width: 960)
        .glassBackgroundEffect()
    }
}

//
//  AILiveHUDView.swift
//  SpatialYOLO
//
//  Iron Man JARVIS / 黑镜 AR HUD 风格覆盖层
//  替代 AI Live 模式下的 DualCameraView，固定尺寸 960×540
//

import SwiftUI

// MARK: - 颜色扩展

extension Color {
    /// HUD 主色：#00E5FF (cyan)
    static let hudCyan = Color(red: 0, green: 0.898, blue: 1.0)
    /// HUD 强调色：#FFB300 (amber)
    static let hudAmber = Color(red: 1.0, green: 0.702, blue: 0)
    /// HUD 背景：near-black
    static let hudBackground = Color(red: 0.04, green: 0.06, blue: 0.08)
    /// 正面情绪色：低饱和绿
    static let hudPositive = Color(red: 0.25, green: 0.72, blue: 0.42)
    /// 负面情绪色：低饱和红
    static let hudNegative = Color(red: 0.82, green: 0.32, blue: 0.32)
}

extension FaceExpression {
    /// 情绪对应的进度条颜色
    var hudBarColor: Color {
        switch self {
        case .happy:
            return .hudPositive
        case .sad, .angry, .disgust, .fear:
            return .hudNegative
        case .neutral, .surprised:
            return .hudCyan
        }
    }
}

// MARK: - AILiveHUDView

struct AILiveHUDView: View {
    let model: AppModel

    private let viewWidth: CGFloat  = 960
    private let viewHeight: CGFloat = 540

    // 扫描线动画
    @State private var scanLineOffset: CGFloat = 0
    @State private var statusPulse: Bool = false
    @State private var sessionSeconds: Int = 0
    @State private var sessionTimer: Timer? = nil

    var body: some View {
        ZStack {
            // Layer 0: 相机图像
            cameraLayer

            // Layer 1: 扫描线
            scanLineLayer

            // Layer 2: YOLO 检测框
            yoloOverlayLayer

            // Layer 3: 人脸检测框 + 数据卡
            faceOverlayLayer

            // Layer 4: 四角 telemetry
            telemetryLayer

            // Layer 5: 外框
            borderLayer
        }
        .frame(width: viewWidth, height: viewHeight)
        .clipped()
        .onAppear {
            startScanLineAnimation()
            startPulse()
        }
        .onDisappear {
            sessionTimer?.invalidate()
        }
    }

    // MARK: - Layer 0: 相机图像

    private var cameraLayer: some View {
        Group {
            if let img = model.capturedImageLeft {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: viewWidth, height: viewHeight)
                    .opacity(0.85)
            } else {
                Rectangle()
                    .fill(Color.hudBackground)
                    .frame(width: viewWidth, height: viewHeight)
            }
        }
    }

    // MARK: - Layer 1: 扫描线

    private var scanLineLayer: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: Color.hudCyan.opacity(0.5), location: 0.5),
                        .init(color: .clear, location: 1)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: viewWidth, height: 3)
            .offset(y: scanLineOffset)
            .animation(.linear(duration: 3).repeatForever(autoreverses: false), value: scanLineOffset)
            .frame(width: viewWidth, height: viewHeight, alignment: .top)
            .clipped()
    }

    // MARK: - Layer 2: YOLO 检测框

    private var yoloOverlayLayer: some View {
        Canvas { context, size in
            let boxes   = model.boundingBoxesLeft
            let classes = model.detectedClassesLeft
            let confs   = model.confidencesLeft
            let dists   = model.objectDistanceMeters

            for i in 0..<boxes.count {
                let box     = boxes[i]
                let cls     = i < classes.count ? classes[i] : ""
                let conf    = i < confs.count   ? confs[i]   : 0
                let distVal = i < dists.count   ? dists[i]   : nil

                // Vision 归一化 → 像素坐标（Y轴翻转）
                let rect = visionToPixel(box, in: size)
                drawLCornerBox(context: context, rect: rect, color: .hudCyan, lineWidth: 1.5, cornerLength: 12)

                // 标签文本
                var label = "\(cls) \(Int(conf))%"
                if let d = distVal { label += " \(Int(d * 100))cm" }
                drawHUDLabel(context: context, text: label, at: CGPoint(x: rect.minX + 2, y: rect.minY - 14),
                             color: .hudCyan)
            }
        }
        .frame(width: viewWidth, height: viewHeight)
    }

    // MARK: - Layer 3: 人脸检测

    private var faceOverlayLayer: some View {
        ZStack {
            // 人脸边框（Canvas）
            Canvas { context, size in
                for face in model.faceDetections {
                    let rect = visionToPixel(face.boundingBox, in: size)
                    drawLCornerBox(context: context, rect: rect, color: .hudAmber, lineWidth: 2.0, cornerLength: 16)
                    drawCrosshair(context: context, center: CGPoint(x: rect.midX, y: rect.midY),
                                  size: 10, color: .hudAmber)
                }
            }
            .frame(width: viewWidth, height: viewHeight)

            // 人脸数据卡（SwiftUI，叠在对应人脸右侧）
            ForEach(model.faceDetections) { face in
                let rect = visionToPixelRect(face.boundingBox)
                FaceDataCard(face: face)
                    .position(x: min(rect.maxX + 110, viewWidth - 10), y: rect.midY)
            }
        }
    }

    // MARK: - Layer 4: 四角 telemetry

    private var telemetryLayer: some View {
        let service = model.activeService
        let framesSent = service.framesSent
        let faceCount  = model.faceDetections.count
        let objCount   = model.boundingBoxesLeft.count
        let sessionStr = formatSessionTime(service)
        let modelName  = model.aiLiveModelName.uppercased()
        let provider   = model.activeProvider.rawValue.uppercased()
        let connected  = service.connectionState == .connected

        return ZStack {
            // 左上
            VStack(alignment: .leading, spacing: 2) {
                Text("SPATIAL·AI v2.0")
                Text("SYS: NOMINAL")
                Text("CAM: ACTIVE")
            }
            .hudTelemetry()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(8)

            // 右上
            VStack(alignment: .trailing, spacing: 2) {
                Text("SESSION \(sessionStr)")
                Text("MDL: \(modelName)")
                Text("DET: \(objCount) OBJS")
            }
            .hudTelemetry()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(8)

            // 左下
            VStack(alignment: .leading, spacing: 2) {
                Text("FACES: \(faceCount)")
                Text("OBJS: \(objCount)")
            }
            .hudTelemetry()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(8)

            // 右下
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Text(connected ? "●" : "○")
                        .foregroundColor(connected ? Color.hudCyan : .gray)
                        .opacity(connected && statusPulse ? 0.5 : 1.0)
                    Text("\(provider) LIVE")
                }
                Text("FRM: \(framesSent)")
            }
            .hudTelemetry()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(8)
        }
        .frame(width: viewWidth, height: viewHeight)
    }

    // MARK: - Layer 5: 外框

    private var borderLayer: some View {
        Rectangle()
            .strokeBorder(Color.hudCyan.opacity(0.5), lineWidth: 1)
            .frame(width: viewWidth, height: viewHeight)
    }

    // MARK: - 动画

    private func startScanLineAnimation() {
        scanLineOffset = -viewHeight / 2
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            scanLineOffset = viewHeight / 2
        }
    }

    private func startPulse() {
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.5)) {
                statusPulse.toggle()
            }
        }
    }

    private func formatSessionTime(_ service: any RealtimeAIService) -> String {
        guard let start = service.sessionStartTime else { return "00:00" }
        let elapsed = Int(Date().timeIntervalSince(start))
        return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    // MARK: - 坐标转换

    private func visionToPixel(_ box: CGRect, in size: CGSize) -> CGRect {
        let x = box.origin.x * size.width
        let y = (1 - box.origin.y - box.height) * size.height
        let w = box.width  * size.width
        let h = box.height * size.height
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func visionToPixelRect(_ box: CGRect) -> CGRect {
        visionToPixel(box, in: CGSize(width: viewWidth, height: viewHeight))
    }

    // MARK: - Canvas 绘制辅助

    private func drawLCornerBox(context: GraphicsContext, rect: CGRect,
                                color: Color, lineWidth: CGFloat, cornerLength: CGFloat) {
        var ctx = context
        ctx.stroke(
            cornerPath(rect: rect, len: cornerLength),
            with: .color(color),
            lineWidth: lineWidth
        )
    }

    private func cornerPath(rect: CGRect, len: CGFloat) -> Path {
        var p = Path()
        let r = rect
        // 左上
        p.move(to: CGPoint(x: r.minX, y: r.minY + len))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + len, y: r.minY))
        // 右上
        p.move(to: CGPoint(x: r.maxX - len, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + len))
        // 右下
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - len))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - len, y: r.maxY))
        // 左下
        p.move(to: CGPoint(x: r.minX + len, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - len))
        return p
    }

    private func drawCrosshair(context: GraphicsContext, center: CGPoint,
                               size: CGFloat, color: Color) {
        var ctx = context
        var p = Path()
        p.move(to: CGPoint(x: center.x - size, y: center.y))
        p.addLine(to: CGPoint(x: center.x + size, y: center.y))
        p.move(to: CGPoint(x: center.x, y: center.y - size))
        p.addLine(to: CGPoint(x: center.x, y: center.y + size))
        ctx.stroke(p, with: .color(color), lineWidth: 1.5)
    }

    private func drawHUDLabel(context: GraphicsContext, text: String,
                              at point: CGPoint, color: Color) {
        // GraphicsContext.draw 只接受 Text，不能加 .background()（会变成 some View）
        context.draw(
            Text(text)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(color),
            at: point,
            anchor: .bottomLeading
        )
    }
}

// MARK: - 人脸数据卡

private struct FaceDataCard: View {
    let face: FaceDetection

    private var top3: [(FaceExpression, Float)] {
        face.expressionScores
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FACE SCAN")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Color.hudAmber)

            ForEach(top3, id: \.0) { expr, score in
                HStack(spacing: 4) {
                    Text(expr.rawValue)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(expr.hudBarColor)
                        .frame(width: 52, alignment: .leading)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(expr.hudBarColor.opacity(0.15))
                            Rectangle()
                                .fill(expr.hudBarColor.opacity(0.8))
                                .frame(width: geo.size.width * CGFloat(score))
                        }
                        .cornerRadius(1)
                    }
                    .frame(width: 40, height: 6)

                    Text("\(Int(score * 100))%")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(expr.hudBarColor)
                        .frame(width: 26, alignment: .trailing)
                }
            }
        }
        .padding(6)
        .background(Color.black.opacity(0.8))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.hudAmber.opacity(0.6), lineWidth: 0.5)
        )
        .cornerRadius(3)
    }
}

// MARK: - Telemetry 文字修饰符

private extension View {
    func hudTelemetry() -> some View {
        self
            .font(.system(size: 9, weight: .regular, design: .monospaced))
            .foregroundColor(Color.hudCyan.opacity(0.9))
            .padding(4)
            .background(Color.black.opacity(0.55))
    }
}

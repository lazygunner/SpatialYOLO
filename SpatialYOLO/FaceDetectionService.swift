//
//  FaceDetectionService.swift
//  SpatialYOLO
//
//  人脸检测服务：使用 Vision 内置 API 检测人脸 + 基于地标几何启发式计算表情分数
//
//  坐标系说明：
//  VNFaceLandmark2D.normalizedPoints 是 face-local 归一化坐标（0-1 在人脸 bbox 内）
//  Vision Y 轴朝上（0 = 人脸底部，1 = 顶部）
//  因此不能再除以 faceW / faceH（那是 image-space 的人脸尺寸，会造成 5-10x 放大）
//

import Vision
import CoreImage
import Foundation

// MARK: - 表情枚举

enum FaceExpression: String, CaseIterable {
    case happy     = "HAPPY"
    case sad       = "SAD"
    case angry     = "ANGRY"
    case surprised = "SURPRISED"
    case fear      = "FEAR"
    case disgust   = "DISGUST"
    case neutral   = "NEUTRAL"
}

// MARK: - 人脸检测结果

struct FaceDetection: Identifiable {
    let id = UUID()
    let boundingBox: CGRect                        // Vision 归一化坐标（左下角原点）
    let expressionScores: [FaceExpression: Float]  // softmax 归一化后的表情分数
}

// MARK: - 人脸检测服务

struct FaceDetectionService {

    /// 从 CVPixelBuffer 检测人脸并计算表情分数
    static func detect(in pixelBuffer: CVPixelBuffer) throws -> [FaceDetection] {
        let request = VNDetectFaceLandmarksRequest()
        request.constellation = .constellation76Points

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])

        guard let results = request.results as? [VNFaceObservation] else { return [] }

        return results.compactMap { observation -> FaceDetection? in
            guard let landmarks = observation.landmarks else { return nil }
            let scores = computeExpressionScores(landmarks: landmarks, face: observation)
            return FaceDetection(boundingBox: observation.boundingBox, expressionScores: scores)
        }
    }

    // MARK: - 表情分数计算

    /// 从 76 点地标几何启发式计算各表情原始分数，再 softmax 归一化
    ///
    /// 策略：先提取几何特征值，再按特征组合打分，避免单一特征误导多个表情。
    /// face-local 典型值：mouthW ≈ 0.35-0.55，MAR ≈ 0.05-0.40，
    ///                    avgBrowEyeGap ≈ 0.08-0.18，innerBrowDist ≈ 0.05-0.25，EAR ≈ 0.15-0.45
    static func computeExpressionScores(landmarks: VNFaceLandmarks2D,
                                        face: VNFaceObservation) -> [FaceExpression: Float] {
        var raw: [FaceExpression: Float] = [:]
        for expr in FaceExpression.allCases { raw[expr] = 0.0 }

        // 过滤掉极小的人脸（太远，地标不准）
        guard face.boundingBox.width > 0.04, face.boundingBox.height > 0.04 else {
            return uniformNeutral()
        }

        // MARK: 1. 提取几何特征（默认值为中性状态典型值）
        var cornerLift: Float    = 0      // 嘴角抬升：正=上扬(happy)，负=下垂(sad)
        var mar: Float           = 0      // 嘴巴开合比
        var mouthW: Float        = 0      // 嘴巴宽度（face-local）
        var avgBrowEyeGap: Float = 0.12   // 眉毛-眼睛 Y 间距（高=上扬，低=压低）
        var innerBrowDist: Float = 0.18   // 内眉 X 间距（小=皱眉）
        var avgEAR: Float        = 0.25   // 眼睛纵横比（大=睁大，小=眯眼）

        if let outerLips = landmarks.outerLips?.normalizedPoints, outerLips.count >= 12 {
            let topY   = Float(outerLips[3].y)
            let botY   = Float(outerLips[9].y)
            let leftX  = Float(outerLips[0].x)
            let rightX = Float(outerLips[6].x)
            let leftY  = Float(outerLips[0].y)
            let rightY = Float(outerLips[6].y)
            mouthW     = abs(rightX - leftX)
            let mouthH = abs(topY - botY)
            mar        = mouthW > 0.05 ? mouthH / mouthW : 0.0
            let centerY    = (topY + botY) / 2.0
            let cornerAvgY = (leftY + rightY) / 2.0
            cornerLift     = cornerAvgY - centerY
        }

        if let lb = landmarks.leftEyebrow?.normalizedPoints,
           let rb = landmarks.rightEyebrow?.normalizedPoints,
           let le = landmarks.leftEye?.normalizedPoints,
           let re = landmarks.rightEye?.normalizedPoints,
           lb.count >= 4, rb.count >= 4, le.count >= 4, re.count >= 4 {
            let lbY = lb.map { Float($0.y) }.reduce(0, +) / Float(lb.count)
            let rbY = rb.map { Float($0.y) }.reduce(0, +) / Float(rb.count)
            let leY = le.map { Float($0.y) }.reduce(0, +) / Float(le.count)
            let reY = re.map { Float($0.y) }.reduce(0, +) / Float(re.count)
            avgBrowEyeGap = ((lbY - leY) + (rbY - reY)) / 2.0
            let liX = lb.last.map  { Float($0.x) } ?? 0.4
            let riX = rb.first.map { Float($0.x) } ?? 0.6
            innerBrowDist = abs(riX - liX)
        }

        if let le = landmarks.leftEye?.normalizedPoints,
           let re = landmarks.rightEye?.normalizedPoints,
           le.count >= 6, re.count >= 6 {
            avgEAR = (eyeAspectRatio(le) + eyeAspectRatio(re)) / 2.0
        }

        // MARK: 2. 表情打分

        // ── HAPPY ──────────────────────────────────────────────────────────────
        // 核心：嘴角上扬。嘴部特征必须以嘴角上扬为前提，防止怒张嘴误判为 happy
        if cornerLift > 0.01 {
            raw[.happy, default: 0] += cornerLift * 15.0
            if mar > 0.08 {
                raw[.happy, default: 0] += (mar - 0.08) * 3.0    // 笑着开嘴
            }
            if mouthW > 0.48 {
                raw[.happy, default: 0] += (mouthW - 0.48) * 12.0 // 开怀大笑
            }
        }
        // 眯眼笑（Duchenne smile）：嘴角上扬且眼睛微闭
        if cornerLift > 0.01 && avgEAR < 0.22 {
            raw[.happy, default: 0] += (0.22 - avgEAR) * 3.0
        }

        // ── SAD ────────────────────────────────────────────────────────────────
        if cornerLift < -0.01 {
            raw[.sad,     default: 0] += (-cornerLift) * 8.0
            raw[.disgust, default: 0] += (-cornerLift) * 2.0
        }
        // 眼睛半闭（无微笑）→ sad / disgust
        if avgEAR < 0.15 && cornerLift <= 0.005 {
            let s = (0.15 - avgEAR) * 2.0
            raw[.sad,     default: 0] += s * 0.5
            raw[.disgust, default: 0] += s * 0.5
        }

        // ── ANGRY ──────────────────────────────────────────────────────────────
        // 眉毛压低（靠近眼睛，典型值 0.08-0.10）
        if avgBrowEyeGap < 0.10 {
            raw[.angry, default: 0] += (0.10 - avgBrowEyeGap) * 5.0
        }
        // 内眉靠近（皱眉）
        if innerBrowDist < 0.12 {
            let f = (0.12 - innerBrowDist) * 6.0
            raw[.angry,   default: 0] += f * 0.5
            raw[.disgust, default: 0] += f * 0.3
            raw[.fear,    default: 0] += f * 0.2
        }
        // 眼睛瞪大 + 眉毛未上扬（区别于 surprised）→ angry
        if avgEAR > 0.28 && avgBrowEyeGap < 0.14 {
            raw[.angry, default: 0] += (avgEAR - 0.28) * 5.0
        }
        // 嘴大张 + 眉毛未上扬（区别于 surprised）→ 怒吼
        if mar > 0.20 && avgBrowEyeGap < 0.14 {
            raw[.angry, default: 0] += (mar - 0.20) * 4.0
        }
        // 嘴宽张开 + 嘴角无上扬 → 怒张嘴
        if mouthW > 0.48 && cornerLift <= 0.005 {
            raw[.angry, default: 0] += (mouthW - 0.48) * 6.0
        }

        // ── SURPRISED ──────────────────────────────────────────────────────────
        // 眉毛上扬（高眉位）
        if avgBrowEyeGap > 0.15 {
            let r = (avgBrowEyeGap - 0.15) * 6.0
            raw[.surprised, default: 0] += r * 0.6
            raw[.fear,      default: 0] += r * 0.4
        }
        // 眼睛大张 + 眉毛上扬 → surprised / fear（眉低则归 angry，见上方）
        if avgEAR > 0.28 && avgBrowEyeGap >= 0.14 {
            let e = (avgEAR - 0.28) * 4.0
            raw[.surprised, default: 0] += e * 0.5
            raw[.fear,      default: 0] += e * 0.5
        }
        // 嘴大张 + 眉毛上扬 → surprised
        if mar > 0.20 && avgBrowEyeGap >= 0.14 {
            raw[.surprised, default: 0] += (mar - 0.20) * 4.0
        }

        // ── DISGUST（追加皱眉+嘴角无上扬）──────────────────────────────────────
        if innerBrowDist < 0.12 && cornerLift < 0.005 {
            raw[.disgust, default: 0] += (0.12 - innerBrowDist) * 2.0
        }

        // MARK: 3. neutral = 1 - 2 * max(其他项)
        let otherMax = FaceExpression.allCases
            .filter { $0 != .neutral }
            .map { raw[$0] ?? 0 }
            .max() ?? 0
        raw[.neutral] = max(0, 1.0 - 2.0 * otherMax)

        // 未触发的表情赋予负基础 logit，压制 softmax 底噪
        var adjusted = raw
        for expr in FaceExpression.allCases {
            if adjusted[expr, default: 0] <= 0 {
                adjusted[expr] = -0.5
            }
        }

        return softmax(adjusted, temperature: 1.5)
    }

    // MARK: - 辅助函数

    /// 眼睛纵横比 EAR（face-local 坐标，不需要除以 faceW/faceH）
    /// pts 是 face-local 0-1 坐标，典型 EAR 范围 0.15-0.45
    private static func eyeAspectRatio(_ pts: [CGPoint]) -> Float {
        guard pts.count >= 6 else { return 0.25 }
        let eyeW = abs(Float(pts[3].x) - Float(pts[0].x))   // 眼睛宽度 ≈ 0.08-0.15
        let h1   = abs(Float(pts[1].y) - Float(pts[5].y))   // 上下对
        let h2   = abs(Float(pts[2].y) - Float(pts[4].y))
        let avgH = (h1 + h2) / 2.0
        return eyeW > 0.01 ? avgH / eyeW : 0.25
    }

    /// Softmax 归一化（temperature 越大分布越平滑）
    private static func softmax(_ scores: [FaceExpression: Float],
                                temperature: Float) -> [FaceExpression: Float] {
        let keys   = FaceExpression.allCases
        let values = keys.map { (scores[$0] ?? 0) / temperature }
        let maxV   = values.max() ?? 0
        let exps   = values.map { exp($0 - maxV) }
        let sum    = exps.reduce(0, +)
        guard sum > 0 else { return uniformNeutral() }
        var result: [FaceExpression: Float] = [:]
        for (i, key) in keys.enumerated() {
            result[key] = exps[i] / sum
        }
        return result
    }

    /// 全部 neutral=1 的均匀分布（fallback）
    private static func uniformNeutral() -> [FaceExpression: Float] {
        var result: [FaceExpression: Float] = [:]
        for expr in FaceExpression.allCases {
            result[expr] = expr == .neutral ? 1.0 : 0.0
        }
        return result
    }
}

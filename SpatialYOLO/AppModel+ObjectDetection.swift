//
//  AppModel+ObjectDetection.swift
//  SpatialYOLO
//
//  Created by 关一鸣 on 2025/3/30.
//

import Vision
import CoreML

extension AppModel {

    func setupVision() {
        switch activeFeature {
        case .spatialYOLO:
            // 双目 yolo11n：左右摄像头同时检测
            setupVisionForCamera(isLeft: true)
            setupVisionForCamera(isLeft: false)
        case .geminiLive:
            // AI Live：仅左摄像头 yolo11n，边检测边发送画面给 AI
            setupVisionForCamera(isLeft: true)
        case .mahjong:
            // 麻将牌专用模型：mahjong_yolo（左摄像头）
            setupMahjongVision()
        }
    }
    
    private func setupVisionForCamera(isLeft: Bool) {
        let yolo11n = try! yolo11n()
        do {
            let visionModel = try VNCoreMLModel(for: yolo11n.model)

            let objectRecognition = VNCoreMLRequest(model: visionModel, completionHandler: { (request, error) in
                if let error = error {
                    print("[YOLO] \(isLeft ? "左" : "右")摄像头识别错误: \(error.localizedDescription)")
                }
                DispatchQueue.main.async(execute: {
                    // perform all the UI updates on the main queue
                    if let results = request.results {
                        self.drawVisionRequestResults(results, request, isLeft: isLeft)
                    } else {
                        if isLeft {
                            self.boundingBoxesLeft = []
                            self.detectedClassesLeft = []
                            self.confidencesLeft = []
                        } else {
                            self.boundingBoxesRight = []
                            self.detectedClassesRight = []
                            self.confidencesRight = []
                        }
                    }
                })
            })
            // 通过参数控制裁剪方式
            objectRecognition.imageCropAndScaleOption = self.imageCropOption
            
            if isLeft {
                self.requestsLeft = [objectRecognition]
            } else {
                self.requestsRight = [objectRecognition]
            }
        } catch let error as NSError {
            print("Model loading went wrong for \(isLeft ? "Left" : "Right") camera: \(error)")
        }
    }
    
    func drawVisionRequestResults(_ results: [Any], _ request: Any, isLeft: Bool) {
        // 清空之前的结果
        if isLeft {
            self.boundingBoxesLeft = []
            self.detectedClassesLeft = []
            self.confidencesLeft = []
        } else {
            self.boundingBoxesRight = []
            self.detectedClassesRight = []
            self.confidencesRight = []
        }
            
        for observation in results where observation is VNRecognizedObjectObservation {
            
            guard let objectObservation = observation as? VNRecognizedObjectObservation else {
                continue
            }
            
            if objectObservation.confidence < 0.5 {
                continue
            }
            // Select only the label with the highest confidence.
            let topLabelObservation = objectObservation.labels[0]
            
            // 存储检测结果
            if isLeft {
                self.boundingBoxesLeft.append(objectObservation.boundingBox)
                self.detectedClassesLeft.append(topLabelObservation.identifier)
                self.confidencesLeft.append(Float(objectObservation.confidence * 100))
            } else {
                self.boundingBoxesRight.append(objectObservation.boundingBox)
                self.detectedClassesRight.append(topLabelObservation.identifier)
                self.confidencesRight.append(Float(objectObservation.confidence * 100))
            }
            
        }
    }
    
    // 为了向后兼容，保留原来的方法（指向左摄像头）
    func drawVisionRequestResults(_ results: [Any], _ request: Any) {
        drawVisionRequestResults(results, request, isLeft: true)
    }

    // MARK: - 麻将牌检测

    /// 42 类麻将牌标签（与模型训练顺序一致）
    static let mahjongClassLabels: [String] = [
        "1B","1C","1D","1F","1S","2B","2C","2D","2F","2S",
        "3B","3C","3D","3F","3S","4B","4C","4D","4F","4S",
        "5B","5C","5D","6B","6C","6D","7B","7C","7D","8B",
        "8C","8D","9B","9C","9D","EW","GD","NW","RD","SW",
        "WD","WW"
    ]

    /// 麻将牌类别编码 → 中文名映射
    static let mahjongClassNames: [String: String] = [
        "1B": "一条", "2B": "二条", "3B": "三条", "4B": "四条", "5B": "五条",
        "6B": "六条", "7B": "七条", "8B": "八条", "9B": "九条",
        "1C": "一万", "2C": "二万", "3C": "三万", "4C": "四万", "5C": "五万",
        "6C": "六万", "7C": "七万", "8C": "八万", "9C": "九万",
        "1D": "一筒", "2D": "二筒", "3D": "三筒", "4D": "四筒", "5D": "五筒",
        "6D": "六筒", "7D": "七筒", "8D": "八筒", "9D": "九筒",
        "EW": "东风", "SW": "南风", "WW": "西风", "NW": "北风",
        "RD": "红中", "GD": "发财", "WD": "白板",
        "1F": "春", "2F": "夏", "3F": "秋", "4F": "冬",
        "1S": "梅", "2S": "兰", "3S": "竹", "4S": "菊", "5S": "百搭",
    ]

    /// 类别编码 → Unicode 麻将牌字符映射
    static let mahjongTileEmojis: [String: String] = [
        // 万（Characters）
        "1C": "\u{1F007}", "2C": "\u{1F008}", "3C": "\u{1F009}",
        "4C": "\u{1F00A}", "5C": "\u{1F00B}", "6C": "\u{1F00C}",
        "7C": "\u{1F00D}", "8C": "\u{1F00E}", "9C": "\u{1F00F}",
        // 条（Bamboo）
        "1B": "\u{1F010}", "2B": "\u{1F011}", "3B": "\u{1F012}",
        "4B": "\u{1F013}", "5B": "\u{1F014}", "6B": "\u{1F015}",
        "7B": "\u{1F016}", "8B": "\u{1F017}", "9B": "\u{1F018}",
        // 筒（Dots）
        "1D": "\u{1F019}", "2D": "\u{1F01A}", "3D": "\u{1F01B}",
        "4D": "\u{1F01C}", "5D": "\u{1F01D}", "6D": "\u{1F01E}",
        "7D": "\u{1F01F}", "8D": "\u{1F020}", "9D": "\u{1F021}",
        // 风（Winds）
        "EW": "\u{1F000}", "SW": "\u{1F001}", "WW": "\u{1F002}", "NW": "\u{1F003}",
        // 箭（Dragons）
        "RD": "\u{1F004}", "GD": "\u{1F005}", "WD": "\u{1F006}",
        // 花（Seasons）
        "1F": "\u{1F026}", "2F": "\u{1F027}", "3F": "\u{1F028}", "4F": "\u{1F029}",
        // 花（Flowers）
        "1S": "\u{1F022}", "2S": "\u{1F023}", "3S": "\u{1F024}", "4S": "\u{1F025}",
        // 百搭
        "5S": "\u{1F0CF}",
    ]

    /// 设置麻将牌 YOLO 检测（原始模型 + Swift 端后处理）
    private func setupMahjongVision() {
        let model = try! mahjong_yolo()
        do {
            let visionModel = try VNCoreMLModel(for: model.model)
            let request = VNCoreMLRequest(model: visionModel) { (request, error) in
                if let error = error {
                    print("[麻将] 检测错误: \(error.localizedDescription)")
                    return
                }
                DispatchQueue.main.async {
                    // 原始模型输出 MLMultiArray，不是 VNRecognizedObjectObservation
                    guard let results = request.results as? [VNCoreMLFeatureValueObservation],
                          let observation = results.first,
                          let multiArray = observation.featureValue.multiArrayValue else {
                        self.mahjongDetections = []
                        return
                    }
                    self.processMahjongOutput(multiArray)
                }
            }
            request.imageCropAndScaleOption = self.imageCropOption
            self.requestsMahjong = [request]
            print("[麻将] 模型加载成功")
        } catch {
            print("[麻将] 模型加载失败: \(error)")
        }
    }

    /// 解析 YOLO 原始输出 [1, 46, 8400] → 边界框 + NMS
    private func processMahjongOutput(_ multiArray: MLMultiArray) {
        let numAnchors = 8400
        let numClasses = 42
        let inputSize: Float = 640.0
        let confThreshold: Float = 0.6
        let iouThreshold: Float = 0.5

        // 计算 scaleFit 的 letterbox 偏移
        // 摄像头图像缩放到 640x640 时的实际占用区域
        var xOffset: Float = 0
        var yOffset: Float = 0
        var scaledW: Float = inputSize
        var scaledH: Float = inputSize
        if cameraImageSize != .zero {
            let imgW = Float(cameraImageSize.width)
            let imgH = Float(cameraImageSize.height)
            let scale = min(inputSize / imgW, inputSize / imgH)
            scaledW = imgW * scale
            scaledH = imgH * scale
            xOffset = (inputSize - scaledW) / 2.0
            yOffset = (inputSize - scaledH) / 2.0
        }

        // 用于存储候选检测
        struct Detection {
            let box: CGRect   // Vision 归一化坐标（左下角原点）
            let cls: String   // 中文类别名
            let code: String  // 类别编码（1B、2C...）
            let conf: Float   // 置信度百分比
        }
        var detections: [Detection] = []

        // 解析 MLMultiArray（shape: [1, 46, 8400]）
        // 数据布局：row-major, [channel][anchor]
        // channel 0-3: cx, cy, w, h（像素坐标，相对于 640x640）
        // channel 4-45: 42 类置信度
        for a in 0..<numAnchors {
            // 提取 bbox（channel 0-3: cx, cy, w, h）
            let aIdx = NSNumber(value: a)
            let cx = multiArray[[0, 0, aIdx]].floatValue
            let cy = multiArray[[0, 1, aIdx]].floatValue
            let w  = multiArray[[0, 2, aIdx]].floatValue
            let h  = multiArray[[0, 3, aIdx]].floatValue

            // 找最大类别分数（channel 4-45）
            var maxScore: Float = 0
            var maxIdx = 0
            for c in 0..<numClasses {
                let score = multiArray[[0, NSNumber(value: 4 + c), NSNumber(value: a)]].floatValue
                if score > maxScore {
                    maxScore = score
                    maxIdx = c
                }
            }

            if maxScore < confThreshold { continue }

            // 从 640x640 letterbox 坐标 → 原始图像归一化坐标
            let xNorm = (cx - xOffset) / scaledW
            let yNorm = (cy - yOffset) / scaledH
            let wNorm = w / scaledW
            let hNorm = h / scaledH

            // 转换为 Vision CGRect（左下角原点，归一化）
            let rect = CGRect(
                x: CGFloat(xNorm - wNorm / 2),
                y: CGFloat(1.0 - yNorm - hNorm / 2),
                width: CGFloat(wNorm),
                height: CGFloat(hNorm)
            )

            let label = AppModel.mahjongClassLabels[maxIdx]
            let displayName = AppModel.mahjongClassNames[label] ?? label
            detections.append(Detection(box: rect, cls: displayName, code: label, conf: maxScore * 100))
        }

        // 按置信度排序
        detections.sort { $0.conf > $1.conf }

        // NMS（非极大值抑制）
        var keep: [Detection] = []
        var suppressed = [Bool](repeating: false, count: detections.count)

        for i in 0..<detections.count {
            if suppressed[i] { continue }
            keep.append(detections[i])

            for j in (i + 1)..<detections.count {
                if suppressed[j] { continue }
                if iou(detections[i].box, detections[j].box) > iouThreshold {
                    suppressed[j] = true
                }
            }
        }

        // 单次原子赋值，避免并行数组竞态导致 SwiftUI 渲染时越界
        self.mahjongDetections = keep.map {
            MahjongTile(box: $0.box, className: $0.cls, classCode: $0.code, confidence: $0.conf)
        }

        // 牌局记忆更新
        if mahjongGameActive {
            updateMahjongHandMemory(detectedCodes: keep.map { $0.code })
        }
    }

    /// 更新牌局记忆：基于当前帧检测结果维护手牌列表
    private func updateMahjongHandMemory(detectedCodes: [String]) {
        // 视线离开时（当前帧无检测结果），冻结手牌记忆，不更新缺席计数
        guard !detectedCodes.isEmpty else {
            // print("[麻将] 视线离开，手牌记忆保持不变 (\(mahjongHandMemory.count)张)")
            return
        }

        // 统计当前帧各牌型出现次数
        var detectedCount: [String: Int] = [:]
        for code in detectedCodes {
            detectedCount[code, default: 0] += 1
        }

        // 统计记忆中各牌型数量
        var memoryCount: [String: Int] = [:]
        for code in mahjongHandMemory {
            memoryCount[code, default: 0] += 1
        }

        // 1. 新增牌（抓牌）：检测到比记忆多的牌
        for (code, count) in detectedCount {
            let inMemory = memoryCount[code] ?? 0
            if count > inMemory {
                for _ in 0..<(count - inMemory) {
                    mahjongHandMemory.append(code)
                }
                // 重置该牌的缺席计数
                mahjongAbsenceCount[code] = 0
            }
        }

        // 2. 更新缺席计数，判断是否打出
        // 重新统计更新后的记忆
        memoryCount = [:]
        for code in mahjongHandMemory {
            memoryCount[code, default: 0] += 1
        }

        for (code, memCount) in memoryCount {
            let detCount = detectedCount[code] ?? 0
            if detCount < memCount {
                // 记忆中有但检测不到（部分或全部），递增缺席计数
                mahjongAbsenceCount[code, default: 0] += 1
            } else {
                // 检测到了，重置缺席计数
                mahjongAbsenceCount[code] = 0
            }
        }

        // 3. 移除连续缺席超过阈值的牌（打出）
        for (code, absCount) in mahjongAbsenceCount {
            if absCount >= mahjongAbsenceThreshold {
                let detCount = detectedCount[code] ?? 0
                let memCount = memoryCount[code] ?? 0
                let toRemove = memCount - detCount  // 移除检测不到的那部分
                if toRemove > 0 {
                    var removed = 0
                    mahjongHandMemory.removeAll { tile in
                        if tile == code && removed < toRemove {
                            removed += 1
                            return true
                        }
                        return false
                    }
                }
                mahjongAbsenceCount[code] = 0
            }
        }

        // 4. 超出手牌上限时，移除置信度最低的牌（可能是误识别）
        enforceHandTileLimit()

        // 按花色排序方便展示
        mahjongHandMemory.sort { a, b in
            let order = mahjongSortKey(a)
            let orderB = mahjongSortKey(b)
            return order < orderB
        }
    }

    /// 超出手牌上限（13/14张）时，按置信度从低到高移除多余的牌
    private func enforceHandTileLimit() {
        guard mahjongHandMemory.count > mahjongMaxHandTiles else { return }

        // 为每类别建立置信度列表（降序），用于逐实例分配
        var detectedByCode: [String: [Float]] = [:]
        for tile in mahjongDetections {
            detectedByCode[tile.classCode, default: []].append(tile.confidence)
        }
        for key in detectedByCode.keys {
            detectedByCode[key]?.sort(by: >)
        }

        // 为记忆中每张牌分配置信度：同类别第1张取最高，第2张取第2高，无检测则为0
        var assignIndex: [String: Int] = [:]
        var tilesWithConf: [(code: String, conf: Float)] = []
        for code in mahjongHandMemory {
            let idx = assignIndex[code, default: 0]
            let conf = (detectedByCode[code]?.indices.contains(idx) == true)
                ? detectedByCode[code]![idx] : 0.0
            tilesWithConf.append((code: code, conf: conf))
            assignIndex[code] = idx + 1
        }

        // 按置信度升序，移除最低的多余牌
        tilesWithConf.sort { $0.conf < $1.conf }
        let excess = mahjongHandMemory.count - mahjongMaxHandTiles
        print("[麻将] 手牌超出上限 \(mahjongHandMemory.count)/\(mahjongMaxHandTiles)，移除 \(excess) 张低置信度牌")

        for item in tilesWithConf.prefix(excess) {
            if let idx = mahjongHandMemory.firstIndex(of: item.code) {
                mahjongHandMemory.remove(at: idx)
                print("[麻将] 移除误识别: \(item.code) (置信度 \(Int(item.conf))%)")
            }
        }
    }

    /// 麻将牌排序键：万(1) < 条(2) < 筒(3) < 风(4) < 箭(5) < 花(6)
    private func mahjongSortKey(_ code: String) -> String {
        let suitOrder: String
        if code == "RD" || code == "GD" || code == "WD" {
            suitOrder = "5"
        } else if ["EW", "SW", "WW", "NW"].contains(code) {
            suitOrder = "4"
        } else if code.hasSuffix("C") {
            suitOrder = "1"
        } else if code.hasSuffix("B") {
            suitOrder = "2"
        } else if code.hasSuffix("D") {
            suitOrder = "3"
        } else {
            suitOrder = "6"
        }
        return "\(suitOrder)_\(code)"
    }

    /// 计算两个矩形的 IoU（交并比）
    private func iou(_ a: CGRect, _ b: CGRect) -> Float {
        let intersection = a.intersection(b)
        if intersection.isNull { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = a.width * a.height + b.width * b.height - intersectionArea
        return unionArea > 0 ? Float(intersectionArea / unionArea) : 0
    }
}

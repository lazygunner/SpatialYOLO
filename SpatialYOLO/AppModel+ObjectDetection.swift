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
            // 为左右摄像头分别初始化 YOLO 模型
            setupVisionForCamera(isLeft: true)
            setupVisionForCamera(isLeft: false)
        case .geminiLive:
            // 仅初始化左摄像头
            setupVisionForGeminiLive()
            self.requestsRight = [] // 清空右摄像头请求
        }
    }

    /// AI Live 专用 YOLO 初始化：动态加载 yolo11s，不存在则回退 yolo11n
    private func setupVisionForGeminiLive() {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU

        // 尝试动态加载 yolo11s.mlmodelc
        var mlModel: MLModel?
        if let url = Bundle.main.url(forResource: "yolo11s", withExtension: "mlmodelc") {
            do {
                mlModel = try MLModel(contentsOf: url, configuration: config)
                aiLiveModelName = "yolo11s"
                print("[YOLO] AI Live 模式: 使用 yolo11s")
            } catch {
                print("[YOLO] yolo11s 加载失败，回退 yolo11n: \(error.localizedDescription)")
            }
        } else {
            print("[YOLO] yolo11s.mlmodelc 未找到，回退 yolo11n")
        }

        // 回退到 yolo11n
        if mlModel == nil {
            mlModel = try! yolo11n().model
            aiLiveModelName = "yolo11n"
            print("[YOLO] AI Live 模式: 使用 yolo11n (回退)")
        }

        guard let finalModel = mlModel else { return }

        do {
            let visionModel = try VNCoreMLModel(for: finalModel)
            let objectRecognition = VNCoreMLRequest(model: visionModel) { (request, error) in
                if let error = error {
                    print("[YOLO] AI Live 左摄像头错误: \(error.localizedDescription)")
                }
                DispatchQueue.main.async {
                    if let results = request.results {
                        self.drawVisionRequestResults(results, request, isLeft: true)
                    } else {
                        self.boundingBoxesLeft = []
                        self.detectedClassesLeft = []
                        self.confidencesLeft = []
                    }
                }
            }
            objectRecognition.imageCropAndScaleOption = self.imageCropOption
            self.requestsLeft = [objectRecognition]
        } catch {
            print("[YOLO] AI Live VNCoreMLModel 创建失败: \(error)")
            // 最终回退：使用标准方法
            setupVisionForCamera(isLeft: true)
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

        // 左摄像头检测框更新后，用最新深度图重新计算各框距离
        if isLeft {
            updateObjectDepths()
        }
    }
    
    // 为了向后兼容，保留原来的方法（指向左摄像头）
    func drawVisionRequestResults(_ results: [Any], _ request: Any) {
        drawVisionRequestResults(results, request, isLeft: true)
    }
}

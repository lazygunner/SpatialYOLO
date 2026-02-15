//
//  AppModel+ObjectDetection.swift
//  SpatialYOLO
//
//  Created by 关一鸣 on 2025/3/30.
//

import Vision

extension AppModel {
        
    func setupVision() {
        // Setup Vision parts for both left and right cameras
        setupVisionForCamera(isLeft: true)
        setupVisionForCamera(isLeft: false)
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
}

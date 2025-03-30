//
//  AppModel+ObjectDetection.swift
//  SpatialYOLO
//
//  Created by 关一鸣 on 2025/3/30.
//

import Vision

extension AppModel {
        
    func setupVision() {
        // Setup Vision parts
        
        let yolo11n = try! yolo11n()
        do {
            let visionModel = try VNCoreMLModel(for: yolo11n.model)

            let objectRecognition = VNCoreMLRequest(model: visionModel, completionHandler: { (request, error) in
                print("objectRecognition\(error)")
                DispatchQueue.main.async(execute: {
                    // perform all the UI updates on the main queue
                    if let results = request.results {
                        self.drawVisionRequestResults(results, request)
                    } else {
                        self.boundingBoxes = []
                        self.detectedClasses = []
                        self.confidences = []
                    }
                })
            })
            // 通过参数控制裁剪方式
            objectRecognition.imageCropAndScaleOption = self.imageCropOption
            self.requests = [objectRecognition]
        } catch let error as NSError {
            print("Model loading went wrong: \(error)")
        }
        
    }
    
    func drawVisionRequestResults(_ results: [Any], _ request: Any) {
        print("Received results type: \(type(of: results))")
        print("Buffer size: \(bufferSize)")
        
        // 清空之前的结果
        self.boundingBoxes = []
        self.detectedClasses = []
        self.confidences = []
            
        for observation in results where observation is VNRecognizedObjectObservation {
            
            guard let objectObservation = observation as? VNRecognizedObjectObservation else {
                continue
            }
            
            if objectObservation.confidence < 0.5 {
                continue
            }
            // Select only the label with the highest confidence.
            let topLabelObservation = objectObservation.labels[0]
            
            print("Normalized bounding box: \(objectObservation.boundingBox)")
                    
            // 存储检测结果
            self.boundingBoxes.append(objectObservation.boundingBox)
            self.detectedClasses.append(topLabelObservation.identifier)
            self.confidences.append(Float(objectObservation.confidence * 100))
            
            print("Detected object: \(topLabelObservation.identifier) with confidence \(objectObservation.confidence * 100)%")
        }
    }
}

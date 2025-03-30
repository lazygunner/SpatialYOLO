//
//  AppModel+ObjectDetection.swift
//  SpatialYOLO
//
//  Created by 关一鸣 on 2025/3/30.
//

import Vision

extension AppModel {
    
    // private var detectionOverlay: CALayer! = nil
    
    func setupVision() {
        // Setup Vision parts
        
//        guard let modelURL = Bundle.main.url(forResource: "yolo11n", withExtension: "mlpackage") else {
//            print("load model error")
//            return
//        }
        let yolo11n = try! yolo11n()
        do {
            let visionModel = try VNCoreMLModel(for: yolo11n.model)
            
            // 硬编码的类别名称JSON
            let classNamesJSON = """
            {
                "0": "person",
                "1": "bicycle",
                "2": "car",
                "3": "motorcycle",
                "4": "airplane",
                "5": "bus",
                "6": "train",
                "7": "truck",
                "8": "boat",
                "9": "traffic light",
                "10": "fire hydrant",
                "11": "stop sign",
                "12": "parking meter",
                "13": "bench",
                "14": "bird",
                "15": "cat",
                "16": "dog",
                "17": "horse",
                "18": "sheep",
                "19": "cow",
                "20": "elephant",
                "21": "bear",
                "22": "zebra",
                "23": "giraffe",
                "24": "backpack",
                "25": "umbrella",
                "26": "handbag",
                "27": "tie",
                "28": "suitcase",
                "29": "frisbee",
                "30": "skis",
                "31": "snowboard",
                "32": "sports ball",
                "33": "kite",
                "34": "baseball bat",
                "35": "baseball glove",
                "36": "skateboard",
                "37": "surfboard",
                "38": "tennis racket",
                "39": "bottle",
                "40": "wine glass",
                "41": "cup",
                "42": "fork",
                "43": "knife",
                "44": "spoon",
                "45": "bowl",
                "46": "banana",
                "47": "apple",
                "48": "sandwich",
                "49": "orange",
                "50": "broccoli",
                "51": "carrot",
                "52": "hot dog",
                "53": "pizza",
                "54": "donut",
                "55": "cake",
                "56": "chair",
                "57": "couch",
                "58": "potted plant",
                "59": "bed",
                "60": "dining table",
                "61": "toilet",
                "62": "tv",
                "63": "laptop",
                "64": "mouse",
                "65": "remote",
                "66": "keyboard",
                "67": "cell phone",
                "68": "microwave",
                "69": "oven",
                "70": "toaster",
                "71": "sink",
                "72": "refrigerator",
                "73": "book",
                "74": "clock",
                "75": "vase",
                "76": "scissors",
                "77": "teddy bear",
                "78": "hair drier",
                "79": "toothbrush"
            }
            """
            
            if let data = classNamesJSON.data(using: .utf8),
               let names = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                // 将字典转换为有序数组
                let sortedNames = names.sorted { Int($0.key)! < Int($1.key)! }.map { $0.value }
                self.classNames = sortedNames
                print("Loaded class names: \(self.classNames)")
            } else {
                print("Failed to parse class names dictionary")
                self.classNames = []
            }
            
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

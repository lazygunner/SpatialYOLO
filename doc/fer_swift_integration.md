# FacialEmotionDetection CoreML 集成说明

## 模型标签顺序（id2label）

```
[0] sad
[1] disgust
[2] angry
[3] neutral
[4] fear
[5] surprise
[6] happy
```

## FaceExpression 映射

Swift 端需要将模型输出的 7 维概率数组按此顺序映射到 `FaceExpression`：

```swift
// 与模型 id2label 顺序一致
private static let modelLabelMap: [Int: FaceExpression] = [
    0: .sad,
    1: .disgust,
    2: .angry,
    3: .neutral,
    4: .fear,
    5: .surprised,
    6: .happy,
]
```

## 预处理参数

- 输入尺寸: **224 × 224 RGB**
- 归一化: mean = `[0.5, 0.5, 0.5]`，std = `[0.5, 0.5, 0.5]`
- 像素值范围: 归一化后 `[-1.0, 1.0]`
- 数据格式: `Float32`，NCHW，batch=1

## FaceDetectionService 修改方案

将 `FaceDetectionService` 改为使用 CoreML 推理替换几何启发式：

```swift
import CoreML
import Vision
import CoreImage

struct FaceDetectionService {

    // 懒加载 CoreML 模型（只初始化一次）
    private static let emotionModel: VNCoreMLModel? = {
        guard let url = Bundle.main.url(
                forResource: "FacialEmotionDetection",
                withExtension: "mlpackage"),
              let mlModel = try? MLModel(contentsOf: url,
                                         configuration: MLModelConfiguration()),
              let vnModel = try? VNCoreMLModel(for: mlModel)
        else {
            print("[FaceDetection] 模型加载失败，回退到几何启发式")
            return nil
        }
        return vnModel
    }()

    static func detect(in pixelBuffer: CVPixelBuffer) throws -> [FaceDetection] {
        // Step 1: 检测人脸矩形（改用更轻量的矩形检测，不需要 landmarks 了）
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([faceRequest])

        guard let faces = faceRequest.results, !faces.isEmpty else { return [] }

        return faces.compactMap { observation -> FaceDetection? in
            guard observation.boundingBox.width > 0.04,
                  observation.boundingBox.height > 0.04 else { return nil }

            let scores = classifyEmotion(pixelBuffer: pixelBuffer,
                                         boundingBox: observation.boundingBox)
            return FaceDetection(boundingBox: observation.boundingBox,
                                 expressionScores: scores)
        }
    }

    // MARK: - CoreML 情绪推理

    private static func classifyEmotion(
        pixelBuffer: CVPixelBuffer,
        boundingBox: CGRect
    ) -> [FaceExpression: Float] {

        guard let model = emotionModel else {
            // 模型未加载时返回 neutral
            return uniformNeutral()
        }

        // 裁剪人脸区域并 resize 到 224×224
        guard let faceBuffer = cropAndResize(pixelBuffer: pixelBuffer,
                                             boundingBox: boundingBox,
                                             targetSize: CGSize(width: 224, height: 224))
        else { return uniformNeutral() }

        // 转换为 MLMultiArray (1, 3, 224, 224)，并做归一化
        guard let inputArray = pixelBufferToMLArray(faceBuffer) else {
            return uniformNeutral()
        }

        // CoreML 推理
        let request = VNCoreMLRequest(model: model)
        let faceHandler = VNImageRequestHandler(cvPixelBuffer: faceBuffer, options: [:])
        // 直接用 MLModel.prediction 更方便
        guard let featureProvider = try? MLDictionaryFeatureProvider(
                  dictionary: ["pixel_values": inputArray]),
              let result = try? model.underlyingModel.prediction(from: featureProvider),
              let probArray = result.featureValue(for: "probabilities")?.multiArrayValue
        else { return uniformNeutral() }

        // 将输出概率数组映射到 FaceExpression
        var scores: [FaceExpression: Float] = [:]
        for (index, expr) in modelLabelMap {
            scores[expr] = index < probArray.count
                ? Float(truncating: probArray[index])
                : 0.0
        }
        return scores
    }

    // MARK: - 图像预处理

    /// 从 CVPixelBuffer 裁剪人脸区域并 resize
    private static func cropAndResize(
        pixelBuffer: CVPixelBuffer,
        boundingBox: CGRect,
        targetSize: CGSize
    ) -> CVPixelBuffer? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let width   = ciImage.extent.width
        let height  = ciImage.extent.height

        // Vision boundingBox: 左下角原点，Y 轴朝上 → 转换为 CoreImage 坐标
        let cropRect = CGRect(
            x:      boundingBox.minX * width,
            y:      (1 - boundingBox.maxY) * height,
            width:  boundingBox.width  * width,
            height: boundingBox.height * height
        )

        let cropped  = ciImage.cropped(to: cropRect)
        let scaleX   = targetSize.width  / cropRect.width
        let scaleY   = targetSize.height / cropRect.height
        let resized  = cropped.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let context  = CIContext()
        var output: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(targetSize.width), Int(targetSize.height),
                            kCVPixelFormatType_32BGRA, nil, &output)
        guard let out = output else { return nil }
        context.render(resized, to: out)
        return out
    }

    /// CVPixelBuffer (224×224) → MLMultiArray (1, 3, 224, 224)，含归一化
    private static func pixelBufferToMLArray(_ buffer: CVPixelBuffer) -> MLMultiArray? {
        let H = 224, W = 224
        guard let array = try? MLMultiArray(
            shape: [1, 3, NSNumber(value: H), NSNumber(value: W)],
            dataType: .float32
        ) else { return nil }

        // 归一化参数（与转换脚本一致）
        let mean: [Float] = [0.5, 0.5, 0.5]
        let std:  [Float] = [0.5, 0.5, 0.5]

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        for y in 0..<H {
            for x in 0..<W {
                let offset = y * bytesPerRow + x * 4
                let b = Float(ptr[offset])     / 255.0
                let g = Float(ptr[offset + 1]) / 255.0
                let r = Float(ptr[offset + 2]) / 255.0

                // NCHW 排列
                array[[0, 0, y, x] as [NSNumber]] = NSNumber(value: (r - mean[0]) / std[0])
                array[[0, 1, y, x] as [NSNumber]] = NSNumber(value: (g - mean[1]) / std[1])
                array[[0, 2, y, x] as [NSNumber]] = NSNumber(value: (b - mean[2]) / std[2])
            }
        }
        return array
    }

    // MARK: - Fallback

    private static func uniformNeutral() -> [FaceExpression: Float] {
        var result: [FaceExpression: Float] = [:]
        for expr in FaceExpression.allCases {
            result[expr] = expr == .neutral ? 1.0 : 0.0
        }
        return result
    }
}
```

## 性能预估（Apple Vision Pro）

| 项目 | 预估值 |
|------|--------|
| 推理延迟（Neural Engine） | ~10-20ms/帧 |
| 模型文件大小（int8 量化后） | ~22 MB |
| 内存占用 | ~80 MB |
| 支持并发 YOLO 推理 | ✓（独立线程） |

## 注意事项

1. 像素格式：`CVPixelBufferGetPixelFormatType` 确保为 `kCVPixelFormatType_32BGRA`（ARKit 默认输出格式），代码中 b/g/r 偏移量已按此处理
2. 检测频率：情绪推理建议维持在 **5fps** 以内，避免与 YOLO 抢 Neural Engine 资源
3. 线程安全：`MLModel` 是线程安全的，可在后台 Task 中推理

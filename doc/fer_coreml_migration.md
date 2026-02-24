# FER CoreML 迁移操作记录

将 `FaceDetectionService` 从几何启发式阈值判断迁移到 CoreML 神经网络模型（ViT-base）进行情绪识别。

---

## 背景

| 项目 | 当前方案 | 目标方案 |
|------|----------|----------|
| 方法 | 几何启发式（眉毛/嘴角/EAR 阈值） | ViT-base CoreML 神经网络推理 |
| 精度 | 低（受光照/角度影响大） | ~91%（dima806 FER 数据集） |
| 情绪类别 | happy/sad/angry/surprised/fear/disgust/neutral | 同上（完全一致） |
| 维护成本 | 高（手动调参） | 低（模型输出概率） |

使用模型：[dima806/facial_emotions_image_detection](https://huggingface.co/dima806/facial_emotions_image_detection)
- 架构：ViT-base-patch16-224，85.8M 参数
- 精度：90.92%
- 输出：7 类情绪 softmax 概率

---

## 第一阶段：转换模型（macOS Python 环境）

### 1.1 安装依赖

```bash
pip install torch torchvision transformers coremltools pillow numpy
```

> 推荐 Python 3.10 或 3.11，coremltools 要求 macOS 12+

### 1.2 运行转换脚本

脚本已写好，位于 `doc/convert_fer_to_coreml.py`

```bash
cd /Volumes/Data/workspace/VP/SpatialYOLO1/doc
python convert_fer_to_coreml.py
```

脚本执行流程：
1. 从 Hugging Face 下载模型（~330MB，需要网络）
2. 添加 softmax 包装层（输出概率而非 logits）
3. 用 `torch.jit.trace` 转换（失败自动回退 `torch.export`）
4. 写入标签/归一化参数到模型 metadata
5. int8 per-channel 量化（体积 330MB → ~22MB）
6. 保存为 `doc/FacialEmotionDetection.mlpackage`

### 1.3 预期输出

```
[1/5] 加载模型: dima806/facial_emotions_image_detection
      参数量  : 85,877,191  (343.5 MB F32)
      标签映射: {0: 'sad', 1: 'disgust', 2: 'angry', 3: 'neutral', 4: 'fear', 5: 'surprise', 6: 'happy'}
[2/5] 转换为 CoreML ...
      ✓ torch.jit.trace 转换成功
[3/5] 写入元数据 ...
[4/5] Int8 权重量化 ...
      ✓ 量化完成
[5/5] 验证推理 ...
      输出 shape : (7,)
      Top 预测   : ...
✓ 保存至: FacialEmotionDetection.mlpackage  (约 22 MB)
```

---

## 第二阶段：将模型添加到 Xcode

1. 打开 Xcode，在项目导航栏中找到 `SpatialYOLO/` 目录
2. 将 `doc/FacialEmotionDetection.mlpackage` 拖入 Xcode
3. 在弹出对话框中：
   - ✅ Copy items if needed
   - ✅ Target: SpatialYOLO
4. 确认 `Build Phases → Copy Bundle Resources` 中包含该文件

---

## 第三阶段：修改 Swift 代码

### 3.1 修改 `FaceDetectionService.swift`

将整个文件替换为以下内容（CoreML 推理版本）：

```swift
//
//  FaceDetectionService.swift
//  SpatialYOLO
//
//  人脸检测服务：Vision 检测人脸位置 + CoreML ViT-base 推理情绪
//

import Vision
import CoreML
import CoreImage
import Foundation

// MARK: - 表情枚举（保持不变）

enum FaceExpression: String, CaseIterable {
    case happy     = "HAPPY"
    case sad       = "SAD"
    case angry     = "ANGRY"
    case surprised = "SURPRISED"
    case fear      = "FEAR"
    case disgust   = "DISGUST"
    case neutral   = "NEUTRAL"
}

// MARK: - 人脸检测结果（保持不变）

struct FaceDetection: Identifiable {
    let id = UUID()
    let boundingBox: CGRect
    let expressionScores: [FaceExpression: Float]
}

// MARK: - 人脸检测服务

struct FaceDetectionService {

    // 模型标签顺序（与 id2label metadata 一致）
    // [0]sad [1]disgust [2]angry [3]neutral [4]fear [5]surprise [6]happy
    private static let modelLabelMap: [Int: FaceExpression] = [
        0: .sad,
        1: .disgust,
        2: .angry,
        3: .neutral,
        4: .fear,
        5: .surprised,
        6: .happy,
    ]

    // 归一化参数（与转换脚本一致，存储在模型 metadata 中）
    private static let normMean: [Float] = [0.5, 0.5, 0.5]
    private static let normStd:  [Float] = [0.5, 0.5, 0.5]

    // 懒加载 CoreML 模型（进程生命周期内只初始化一次）
    private static let emotionModel: MLModel? = {
        guard let url = Bundle.main.url(
            forResource: "FacialEmotionDetection",
            withExtension: "mlpackage"
        ) else {
            print("[FaceDetection] 找不到 FacialEmotionDetection.mlpackage")
            return nil
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all  // 优先 Neural Engine
        do {
            return try MLModel(contentsOf: url, configuration: config)
        } catch {
            print("[FaceDetection] 模型加载失败: \(error)")
            return nil
        }
    }()

    // MARK: - 主入口

    static func detect(in pixelBuffer: CVPixelBuffer) throws -> [FaceDetection] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])

        guard let results = request.results, !results.isEmpty else { return [] }

        return results.compactMap { observation -> FaceDetection? in
            guard observation.boundingBox.width  > 0.04,
                  observation.boundingBox.height > 0.04 else { return nil }

            let scores = classifyEmotion(
                pixelBuffer: pixelBuffer,
                boundingBox: observation.boundingBox
            )
            return FaceDetection(
                boundingBox: observation.boundingBox,
                expressionScores: scores
            )
        }
    }

    // MARK: - CoreML 情绪推理

    private static func classifyEmotion(
        pixelBuffer: CVPixelBuffer,
        boundingBox: CGRect
    ) -> [FaceExpression: Float] {
        guard let model = emotionModel else { return uniformNeutral() }

        guard let faceBuffer = cropAndResize(
            pixelBuffer: pixelBuffer,
            boundingBox: boundingBox,
            targetSize: CGSize(width: 224, height: 224)
        ) else { return uniformNeutral() }

        guard let inputArray = pixelBufferToMLArray(faceBuffer) else {
            return uniformNeutral()
        }

        do {
            let provider = try MLDictionaryFeatureProvider(
                dictionary: ["pixel_values": MLFeatureValue(multiArray: inputArray)]
            )
            let result = try model.prediction(from: provider)
            guard let probArray = result.featureValue(for: "probabilities")?.multiArrayValue
            else { return uniformNeutral() }

            var scores: [FaceExpression: Float] = [:]
            for (index, expr) in modelLabelMap {
                scores[expr] = index < probArray.count
                    ? Float(truncating: probArray[index])
                    : 0.0
            }
            return scores
        } catch {
            print("[FaceDetection] 推理失败: \(error)")
            return uniformNeutral()
        }
    }

    // MARK: - 图像预处理

    /// Vision boundingBox（左下角原点） → 裁剪 + resize → CVPixelBuffer 224×224
    private static func cropAndResize(
        pixelBuffer: CVPixelBuffer,
        boundingBox: CGRect,
        targetSize: CGSize
    ) -> CVPixelBuffer? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let w = ciImage.extent.width
        let h = ciImage.extent.height

        // Vision Y 轴朝上 → CoreImage Y 轴朝下转换
        let cropRect = CGRect(
            x:      boundingBox.minX * w,
            y:      (1.0 - boundingBox.maxY) * h,
            width:  boundingBox.width  * w,
            height: boundingBox.height * h
        )

        let scaleX  = targetSize.width  / cropRect.width
        let scaleY  = targetSize.height / cropRect.height
        let resized = ciImage
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        var output: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey  as String: Int(targetSize.width),
            kCVPixelBufferHeightKey as String: Int(targetSize.height),
        ]
        CVPixelBufferCreate(nil, Int(targetSize.width), Int(targetSize.height),
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &output)
        guard let out = output else { return nil }

        CIContext().render(resized, to: out)
        return out
    }

    /// CVPixelBuffer (224×224 BGRA) → MLMultiArray (1,3,224,224)，含归一化
    private static func pixelBufferToMLArray(_ buffer: CVPixelBuffer) -> MLMultiArray? {
        let H = 224, W = 224
        guard let array = try? MLMultiArray(
            shape: [1, 3, NSNumber(value: H), NSNumber(value: W)],
            dataType: .float32
        ) else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        let ptr32 = array.dataPointer.assumingMemoryBound(to: Float32.self)
        let channelStride = H * W

        for y in 0..<H {
            for x in 0..<W {
                let offset = y * bytesPerRow + x * 4
                let b = Float(ptr[offset])     / 255.0
                let g = Float(ptr[offset + 1]) / 255.0
                let r = Float(ptr[offset + 2]) / 255.0
                // NCHW: channel 0=R, 1=G, 2=B
                ptr32[0 * channelStride + y * W + x] = (r - normMean[0]) / normStd[0]
                ptr32[1 * channelStride + y * W + x] = (g - normMean[1]) / normStd[1]
                ptr32[2 * channelStride + y * W + x] = (b - normMean[2]) / normStd[2]
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

### 3.2 修改检测频率（`AppModel+GeminiLive.swift` 或人脸检测调用处）

CoreML ViT 推理比几何算法慢，建议降低人脸检测频率：

```swift
// 找到人脸检测的调用位置，将频率从 30fps 降低到 5fps
// 例如在帧处理回调中加入节流：

private var lastFaceDetectionTime: Date = .distantPast

// 在处理帧的地方：
let now = Date()
if now.timeIntervalSince(lastFaceDetectionTime) > 0.2 {  // 5fps
    lastFaceDetectionTime = now
    // 执行人脸检测
    if let detections = try? FaceDetectionService.detect(in: pixelBuffer) {
        self.faceDetections = detections
    }
}
```

---

## 第四阶段：验证

构建并运行后，观察 FaceDataCard 中的情绪分布是否合理：

- 明显微笑 → HAPPY 应 > 30%
- 明显愤怒（瞪眼张嘴）→ ANGRY 应 > 30%
- 平静表情 → NEUTRAL 应 > 35%
- 情绪置信度整体应高于几何启发式版本

---

## 回滚方案

如果 CoreML 模型集成后效果不理想，`FaceDetectionService.swift` 的几何启发式版本已保存在 git 历史中：

```bash
git show HEAD:SpatialYOLO/FaceDetectionService.swift
```

---

## 文件清单

| 文件 | 说明 |
|------|------|
| `doc/convert_fer_to_coreml.py` | Python 转换脚本 |
| `doc/fer_swift_integration.md` | Swift 集成技术参考 |
| `doc/fer_coreml_migration.md` | 本文档（操作步骤） |
| `SpatialYOLO/FacialEmotionDetection.mlpackage` | 转换后模型（需执行脚本生成） |
| `SpatialYOLO/FaceDetectionService.swift` | 需替换为上方 CoreML 版本 |

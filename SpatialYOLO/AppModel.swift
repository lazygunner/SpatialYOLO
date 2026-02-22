//
//  AppModel.swift
//  SpatialYOLO
//
//  Created by 关一鸣 on 2025/3/30.
//

import SwiftUI
import ARKit
import RealityKit
import Vision
import simd
import CoreML
import Accelerate
import VisionEntitlementServices

/// Maintains app-wide state
@MainActor
@Observable
public class AppModel: ObservableObject {
    let immersiveSpaceID = "ImmersiveSpace"
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.closed

    /// 功能模式
    enum FeatureMode {
        case spatialYOLO    // 双目 YOLO 检测 + 深度估计
        case geminiLive     // Gemini Live 交互助手
        case mahjong        // 麻将牌检测 + AI 助手
    }
    var activeFeature: FeatureMode = .spatialYOLO

    var selectedTab = 0
    
    var arKitSession = ARKitSession()
    var worldTracking = WorldTrackingProvider()

    // 左摄像头相关
    var capturedImageLeft: UIImage?
    var cameraImageSize: CGSize = .zero  // 摄像头原始分辨率（用于坐标换算）
    private var pixelBufferLeft: CVPixelBuffer?
    var boundingBoxesLeft: [CGRect] = []
    var detectedClassesLeft: [String] = []
    var confidencesLeft: [Float] = []

    // 右摄像头相关
    var capturedImageRight: UIImage?
    private var pixelBufferRight: CVPixelBuffer?
    var boundingBoxesRight: [CGRect] = []
    var detectedClassesRight: [String] = []
    var confidencesRight: [Float] = []

    // 深度图相关
    var depthImage: UIImage?
    private var depthPixelBuffer: CVPixelBuffer?

    // 深度距离融合
    var rawDepthValues: [Float] = []        // 深度图原始深度值（512×512 展开，值越小越近）
    var depthMinVal: Float = 0              // 本帧最小深度（对应最近点）
    var depthMaxVal: Float = 0             // 本帧最大深度（对应最远点）
    var depthCropX: Int = 0                 // 深度预处理的裁剪偏移 X
    var depthCropY: Int = 0                 // 深度预处理的裁剪偏移 Y
    var depthScaleFactor: Float = 1.0       // 深度预处理的缩放系数
    var objectDepths: [Float?] = []         // 与 boundingBoxesLeft 并行：相对距离（0=近, 1=远）
    var objectDistanceMeters: [Float?] = [] // 与 boundingBoxesLeft 并行：估算距离（米）
    
    // 相机标定参数（首帧捕获，之后固定不变）
    private var hasCalibration = false
    var actualBaseline: Float = 0.065   // 双目基线（米），由标定流程更新

    // 深度来源
    enum DepthSource { case stereo, monocular }
    var depthSource: DepthSource = .stereo
    var depthModelSize: Int = 512    // 当前深度图宽度（stereo=512, monocular=518）
    var depthModelHeight: Int = 512  // 当前深度图高度（stereo=512, monocular=392）

    // 深度估计模型和像素缓冲池
    private var depthModel: RaftStereo512?
    private var monocularDepthModel: MLModel?   // DepthAnythingV2Small，用通用 MLModel 避免编译依赖
    private var pixelBufferPool: CVPixelBufferPool?          // 512×512 for RaftStereo
    private var monocularPixelBufferPool: CVPixelBufferPool? // 518×518 for DepthAnything
    private var stackedBufferPool: CVPixelBufferPool?
    private let ciContext = CIContext()

    private var cameraAccessAuthorizationStatus = ARKitSession.AuthorizationStatus.notDetermined
    var panelAttachment: Entity = Entity()
    // ARKit Hand Tracking
    var handTrackingPermitted = false
    var showARTryOnInstruction = true
    
    var instructionAttachment: Entity = Entity()
    
    // Vision parts - 为左右摄像头分别创建
    var requestsLeft = [VNRequest]()
    var requestsRight = [VNRequest]()
    var bufferSize: CGSize = .zero
    var classNames: [String] = []

    // 麻将检测相关（单一数组避免并行数组竞态）
    struct MahjongTile: Identifiable {
        let id = UUID()
        let box: CGRect        // Vision 归一化坐标
        let className: String  // 中文显示名（一条、二万...）
        let classCode: String  // 类别编码（1B、2C...用于 emoji 映射）
        let confidence: Float  // 置信度百分比
    }
    var mahjongDetections: [MahjongTile] = []   // 当前帧检测结果
    var requestsMahjong = [VNRequest]()

    // 牌局记忆
    var mahjongGameActive: Bool = false          // 牌局是否进行中
    var mahjongHandMemory: [String] = []         // 记忆中的手牌（类别编码，可重复）
    /// 每张牌连续未检测到的帧数（用于判断是否被打出）
    var mahjongAbsenceCount: [String: Int] = [:]
    /// 连续未检测到多少帧后判定为已打出
    let mahjongAbsenceThreshold = 15     // 约 0.5 秒 @30fps

    /// 手牌状态：等待摸牌（13张上限）或等待打牌（14张上限）
    enum MahjongHandState {
        case waitingToDraw      // 待摸牌，最多 13 张
        case waitingToDiscard   // 待打牌，最多 14 张
    }
    var mahjongHandState: MahjongHandState = .waitingToDiscard
    var mahjongMaxHandTiles: Int { mahjongHandState == .waitingToDiscard ? 14 : 13 }

    /// 控制面板是否展开（收起/展开按钮控制）
    var mahjongPanelExpanded: Bool = true

    // MARK: - 打牌记录（其他玩家）
    var discardRecords: [PlayerDiscardRecord] = []   // 按玩家分组的打牌记录
    
    var currentIntrinsics: simd_float3x3 = simd_float3x3(.zero)
    var currentExtrinsics: simd_float4x4 = simd_float4x4(.zero)
    var deviceTransform: Transform = Transform()
    var trackingPoint: SIMD3<Float> = .zero
    var trackingEnt = Entity()
    
    var imageCropOption: VNImageCropAndScaleOption = .scaleFit

    // 为了向后兼容，保留原来的属性（指向左摄像头）
    var capturedImage: UIImage? { capturedImageLeft }
    var boundingBoxes: [CGRect] { boundingBoxesLeft }
    var detectedClasses: [String] { detectedClassesLeft }
    var confidences: [Float] { confidencesLeft }
    var requests: [VNRequest] {
        get { requestsLeft }
        set { requestsLeft = newValue }
    }

    // MARK: - 各模式独立系统提示词

    /// AI Live 模式：通用视觉助手，负责观察环境、回答问题
    static let aiLiveSystemInstruction = """
    你是 Apple Vision Pro 上的智能视觉助手。通过摄像头实时观察用户周围的环境。
    你的能力：描述所见场景和物体、回答用户关于环境的问题、提供实用建议。
    要求：始终用中文回答，语言简洁自然，不超过3句话。
    """

    /// 麻将模式：专注监听牌局动作，结构化输出打牌事件
    static let mahjongSystemInstruction = """
    你是麻将牌局语音监听助手，通过 Apple Vision Pro 旁听牌局。
    核心任务：仔细听取周围玩家的声音，识别报牌和动作，区分玩家A/B/C。
    每当检测到打牌动作，必须用以下格式逐行输出（不得省略）：
    [玩家A] 打 三万
    [玩家B] 碰
    [玩家C] 杠 东风
    [玩家A] 胡
    规则：只输出打牌相关信息，忽略闲聊；初始静默监听，不主动发言；极简中文。
    """

    // MARK: - AI 服务
    var activeProvider: AIProvider = .qwen
    var geminiService = GeminiLiveService(apiKey: AppModel.loadGeminiAPIKey())
    var qwenService = QwenOmniService(apiKey: AppModel.loadQwenAPIKey())
    var activeService: any RealtimeAIService {
        switch activeProvider {
        case .gemini: return geminiService
        case .qwen: return qwenService
        }
    }
    var isGeminiActive: Bool = false
    var userInputText: String = ""
    private var lastGeminiSendTime = Date.distantPast

    // MARK: - 麻将牌型分析服务（独立 LLM）
    var mahjongAnalysisService = MahjongAnalysisService(apiKey: AppModel.loadQwenAPIKey())

    // MARK: - 企业许可证
    var isLicenseValid: Bool = false
    var isCameraEntitled: Bool = false

    /// 检查企业许可证和主摄像头权限
    func checkLicenseStatus() {
        let license = EnterpriseLicenseDetails.shared
        print(license.expirationTimestamp)

        guard license.licenseStatus == .valid else {
            print("企业许可证无效: \(license.licenseStatus)")
            isLicenseValid = false
            isCameraEntitled = false
            return
        }

        isLicenseValid = true

        if license.isApproved(for: .mainCameraAccess) {
            print("主摄像头访问已授权，启用功能...")
            isCameraEntitled = true
        } else {
            print("主摄像头访问未获批准")
            isCameraEntitled = false
        }
    }

    /// 从 Config.plist 读取 Gemini API Key
    private static func loadGeminiAPIKey() -> String {
        guard let url = Bundle.main.url(forResource: "Config", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let apiKey = dict["GEMINI_API_KEY"] as? String,
              apiKey != "YOUR_API_KEY_HERE" else {
            print("警告: 未找到有效的 Gemini API Key，请在 Config.plist 中配置 GEMINI_API_KEY")
            return ""
        }
        return apiKey
    }

    /// 从 Config.plist 读取 Qwen API Key
    private static func loadQwenAPIKey() -> String {
        guard let url = Bundle.main.url(forResource: "Config", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let apiKey = dict["QWEN_API_KEY"] as? String,
              apiKey != "YOUR_API_KEY_HERE" else {
            print("警告: 未找到有效的 Qwen API Key，请在 Config.plist 中配置 QWEN_API_KEY")
            return ""
        }
        return apiKey
    }

    // 初始化深度模型（双目 + 单目）
    private func initializeDepthModel() {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU

        do {
            depthModel = try RaftStereo512(configuration: config)
            print("RaftStereo512 初始化成功")
        } catch {
            print("RaftStereo512 初始化失败: \(error)")
        }

        // 单目深度：从 Bundle 动态加载，避免对自动生成类的编译依赖
        // 需先运行 doc/convert_depth_anything.py 并将产物加入 Xcode Target
        // 下载：https://huggingface.co/apple/coreml-depth-anything-v2-small
        // 推荐使用 DepthAnythingV2SmallF16.mlpackage（49.8 MB）
        let monocularModelName = "DepthAnythingV2SmallF16"
        if let modelURL = Bundle.main.url(forResource: monocularModelName, withExtension: "mlmodelc") {
            do {
                monocularDepthModel = try MLModel(contentsOf: modelURL, configuration: config)
                print("\(monocularModelName) 初始化成功")
            } catch {
                print("\(monocularModelName) 加载失败: \(error.localizedDescription)")
            }
        } else {
            print("\(monocularModelName).mlmodelc 未找到，单目深度不可用")
            print("  → 从 https://huggingface.co/apple/coreml-depth-anything-v2-small 下载并添加到 Xcode Target")
        }
    }
    
    // 重新缩放图像到512x512
    private func rescaleImage(pixelBuffer: CVPixelBuffer) -> (CVPixelBuffer, Float, Int, Int)? {
        if pixelBufferPool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 512,
                kCVPixelBufferHeightKey as String: 512,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pixelBufferPool)
        }
        
        guard let pool = pixelBufferPool else { return nil }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        
        let cropSize = min(sourceWidth, sourceHeight)
        let cropX = (sourceWidth - cropSize) / 2
        let cropY = (sourceHeight - cropSize) / 2
        
        let cropRect = CGRect(x: cropX, y: cropY, width: cropSize, height: cropSize)
        let croppedImage = CIImage(cvPixelBuffer: pixelBuffer).cropped(to: cropRect)

        let scale = 512.0 / CGFloat(cropSize)
        let translate = CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y)
        let scaleTransform = CGAffineTransform(scaleX: scale, y: scale)

        let ciImage = croppedImage.transformed(by: translate.concatenating(scaleTransform))
        
        var outputBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
        
        guard let output = outputBuffer else {
            print("无法从像素缓冲池分配 CVPixelBuffer")
            return nil
        }
        
        ciContext.render(ciImage, to: output, bounds: CGRect(x: 0, y: 0, width: 512, height: 512), colorSpace: CGColorSpaceCreateDeviceRGB())
        
        return (output, 512.0 / Float(cropSize), cropX, cropY)
    }
    
    /// 按需初始化 CVPixelBufferPool（BGRA 格式，支持非正方形）
    private func ensurePool(_ pool: inout CVPixelBufferPool?, width: Int, height: Int) {
        guard pool == nil else { return }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    }

    // 将深度 MLMultiArray 转换为可显示的 BGRA 图像
    // pool 必须预先由 ensurePool 初始化，且尺寸与 multiArray 的 H×W 匹配
    private func multiArrayToRGBA(_ multiArray: MLMultiArray, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        guard multiArray.dataType == .float32,
              multiArray.shape.count == 4,
              multiArray.shape[0].intValue == 1,
              multiArray.shape[1].intValue == 1 else {
            print("不支持的形状或类型")
            return nil
        }

        let height = multiArray.shape[2].intValue
        let width = multiArray.shape[3].intValue
        let count = width * height

        // 绑定到 float32 指针
        let floatPtr = multiArray.dataPointer.bindMemory(to: Float.self, capacity: count)
        let buffer = UnsafeBufferPointer(start: floatPtr, count: count)

        // 找到最小值和最大值
        var minVal: Float = 0
        var maxVal: Float = 0
        vDSP_minv(floatPtr, 1, &minVal, vDSP_Length(count))
        vDSP_maxv(floatPtr, 1, &maxVal, vDSP_Length(count))

        let range = maxVal - minVal
        if range == 0 {
            print("数值均匀 — 无法缩放")
            return nil
        }

        // 创建像素缓冲区
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)

        guard let bufferOut = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(bufferOut, [])
        defer { CVPixelBufferUnlockBaseAddress(bufferOut, []) }

        let outBase = CVPixelBufferGetBaseAddress(bufferOut)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(bufferOut)

        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let value = buffer[i]

                // 标准化到 [0, 1]
                let norm = (value - minVal) / range
                let scaled = UInt8(clamping: Int(norm * 255))

                let pixelPtr = outBase + y * bytesPerRow + x * 4
                pixelPtr[0] = scaled     // R
                pixelPtr[1] = scaled     // G
                pixelPtr[2] = scaled     // B
                pixelPtr[3] = 255        // A (完全不透明)
            }
        }

        return bufferOut
    }
    
    // MARK: - 深度估计调度

    /// 根据 depthSource 选择双目或单目深度估计
    private func processDepthEstimation() async {
        switch depthSource {
        case .stereo:    await processStereoDepth()
        case .monocular: await processMonocularDepth()
        }
    }

    // 双目深度（RaftStereo512）：同时需要左右两路画面
    private func processStereoDepth() async {
        guard let model = depthModel,
              let leftBuffer = pixelBufferLeft,
              let rightBuffer = pixelBufferRight else { return }

        guard let leftRescaled  = rescaleImage(pixelBuffer: leftBuffer),
              let rightRescaled = rescaleImage(pixelBuffer: rightBuffer) else { return }

        do {
            let prediction = try await model.prediction(
                input: RaftStereo512Input(left_: leftRescaled.0, right_: rightRescaled.0))

            ensurePool(&pixelBufferPool, width: 512, height: 512)
            if let pool = pixelBufferPool,
               let depthBuffer = multiArrayToRGBA(prediction.var_4967, pool: pool) {
                self.depthPixelBuffer = depthBuffer
                self.depthImage = convertToUIImage(pixelBuffer: depthBuffer)
            }
            storeDepthData(prediction.var_4967,
                           modelSize: 512,
                           scale: leftRescaled.1,
                           cropX: leftRescaled.2,
                           cropY: leftRescaled.3)
        } catch {
            print("双目深度估计错误: \(error)")
        }
    }

    // 单目深度（Depth Anything V2 Small）：只需左摄像头
    // Apple 官方 CoreML 模型输出 depth 为灰度 CVPixelBuffer（不是 MLMultiArray）
    // 模型：https://huggingface.co/apple/coreml-depth-anything-v2-small
    private func processMonocularDepth() async {
        guard let model = monocularDepthModel,
              let leftBuffer = pixelBufferLeft else { return }

        guard let rescaled = rescaleImageMonocular(pixelBuffer: leftBuffer) else { return }

        do {
            let inputProvider = try MLDictionaryFeatureProvider(
                dictionary: ["image": MLFeatureValue(pixelBuffer: rescaled.0)]
            )
            let outputProvider = try await model.prediction(from: inputProvider)
            guard let depthFeature = outputProvider.featureValue(for: "depth") else { return }

            if let depthBuffer = depthFeature.imageBufferValue {
                // 正常路径：Apple 模型输出灰度 CVPixelBuffer
                // 模型输出视差方向（亮=近），翻转后符合深度图直觉（亮=远）
                let ci = CIImage(cvPixelBuffer: depthBuffer).applyingFilter("CIColorInvert")
                if let cg = ciContext.createCGImage(ci, from: ci.extent) {
                    self.depthImage = UIImage(cgImage: cg)
                }
                storeDepthDataFromGrayscale(depthBuffer,
                                            scale: rescaled.1,
                                            cropX: rescaled.2,
                                            cropY: rescaled.3)
            } else if let depthArray = depthFeature.multiArrayValue {
                // 备用路径：MLMultiArray 输出（自定义转换模型）
                ensurePool(&monocularPixelBufferPool, width: 518, height: 392)
                if let pool = monocularPixelBufferPool,
                   let depthBuffer = multiArrayToRGBA(depthArray, pool: pool) {
                    self.depthImage = convertToUIImage(pixelBuffer: depthBuffer)
                }
                storeDepthData(depthArray, modelSize: 518,
                               scale: rescaled.1, cropX: rescaled.2, cropY: rescaled.3)
            }
        } catch {
            print("单目深度估计错误: \(error)")
        }
    }

    /// 缩放图像到 518×392（Depth Anything V2 固定输入尺寸）
    /// 相机帧 1920×1440（AR=1.333）与模型输入 518×392（AR=1.321）接近，只裁极少量宽度
    private func rescaleImageMonocular(pixelBuffer: CVPixelBuffer) -> (CVPixelBuffer, Float, Int, Int)? {
        let targetW = 518, targetH = 392
        let targetAR = Float(targetW) / Float(targetH)  // 1.3214

        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)

        // 以高度为基准计算裁剪宽度，使宽高比与模型输入一致
        let cropW = Int(Float(srcH) * targetAR + 0.5)
        let cropH = srcH
        let cropX = (srcW - cropW) / 2
        let cropY = 0

        let cropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
        let scale    = Float(targetH) / Float(cropH)   // 统一缩放系数（宽高相同）

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let translate      = CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y)
        let scaleTransform = CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale))
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            .cropped(to: cropRect)
            .transformed(by: translate.concatenating(scaleTransform))

        var tempPool: CVPixelBufferPool?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: targetW,
            kCVPixelBufferHeightKey as String: targetH,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &tempPool)
        guard let pool = tempPool else { return nil }

        var outputBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
        guard let output = outputBuffer else { return nil }

        ciContext.render(ciImage, to: output,
                         bounds: CGRect(x: 0, y: 0, width: targetW, height: targetH),
                         colorSpace: CGColorSpaceCreateDeviceRGB())

        return (output, scale, cropX, cropY)
    }

    // MARK: - 深度距离融合

    /// 存储深度数组及裁剪参数，供检测框距离估算使用
    private func storeDepthData(_ multiArray: MLMultiArray,
                                modelSize: Int,
                                scale: Float,
                                cropX: Int,
                                cropY: Int) {
        guard multiArray.dataType == .float32,
              multiArray.shape.count == 4,
              multiArray.shape[2].intValue == modelSize,
              multiArray.shape[3].intValue == modelSize else { return }

        let count = modelSize * modelSize
        let floatPtr = multiArray.dataPointer.bindMemory(to: Float.self, capacity: count)

        var minVal: Float = 0
        var maxVal: Float = 0
        vDSP_minv(floatPtr, 1, &minVal, vDSP_Length(count))
        vDSP_maxv(floatPtr, 1, &maxVal, vDSP_Length(count))

        self.rawDepthValues   = Array(UnsafeBufferPointer(start: floatPtr, count: count))
        self.depthMinVal      = minVal
        self.depthMaxVal      = maxVal
        self.depthModelSize   = modelSize
        self.depthModelHeight = modelSize   // RAFT 输出为正方形
        self.depthCropX       = cropX
        self.depthCropY       = cropY
        self.depthScaleFactor = scale

        updateObjectDepths()
    }

    /// 从灰度 CVPixelBuffer 提取深度值并存储（Apple 官方模型输出格式）
    /// 支持 OneComponent32Float（float32）和 OneComponent8（uint8 归一化）两种像素格式
    private func storeDepthDataFromGrayscale(_ depthBuffer: CVPixelBuffer,
                                             scale: Float,
                                             cropX: Int,
                                             cropY: Int) {
        let width  = CVPixelBufferGetWidth(depthBuffer)
        let height = CVPixelBufferGetHeight(depthBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(depthBuffer)
        let count  = width * height

        CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly) }

        guard let baseAddr = CVPixelBufferGetBaseAddress(depthBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthBuffer)

        var values = [Float](repeating: 0, count: count)

        if pixelFormat == kCVPixelFormatType_OneComponent32Float {
            let floatPtr = baseAddr.assumingMemoryBound(to: Float.self)
            let stride   = bytesPerRow / MemoryLayout<Float>.size
            for y in 0..<height {
                for x in 0..<width {
                    values[y * width + x] = floatPtr[y * stride + x]
                }
            }
        } else {
            // 8-bit 灰度（OneComponent8），归一化到 [0, 1]
            let uint8Ptr = baseAddr.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    values[y * width + x] = Float(uint8Ptr[y * bytesPerRow + x]) / 255.0
                }
            }
        }

        let n = vDSP_Length(count)
        var minVal: Float = 0, maxVal: Float = 0
        values.withUnsafeMutableBufferPointer {
            vDSP_minv($0.baseAddress!, 1, &minVal, n)
            vDSP_maxv($0.baseAddress!, 1, &maxVal, n)
        }

        // Depth Anything V2 输出视差方向（值越大越近），翻转为深度约定（值越大越远）
        // 翻转后：depthMinVal = 最近, depthMaxVal = 最远，与 RAFT 语义一致
        let rMin = minVal, rMax = maxVal
        for i in 0..<count { values[i] = rMax + rMin - values[i] }
        // 翻转不改变值域范围，只改变空间分布，min/max 不变

        self.rawDepthValues   = values
        self.depthMinVal      = minVal
        self.depthMaxVal      = maxVal
        self.depthModelSize   = width
        self.depthModelHeight = height
        self.depthCropX       = cropX
        self.depthCropY       = cropY
        self.depthScaleFactor = scale

        updateObjectDepths()
    }

    // MARK: - 相机标定参数捕获

    /// 从 CameraFrame.Sample.parameters 读取内参矩阵和基线（首帧调用一次即可）
    ///
    /// CameraFrame.Sample.Parameters 直接暴露 intrinsics (simd_float3x3) 和
    /// extrinsics (simd_float4x4)，无需从 CVPixelBuffer 附件解析。
    func captureCalibration(leftSample: CameraFrame.Sample, rightSample: CameraFrame.Sample) {
        guard !hasCalibration else { return }
        defer { hasCalibration = true }

        // 1. 内参矩阵（焦距 fx/fy、主点 cx/cy）
        //    simd_float3x3 列主序：columns.0=(fx,0,0), columns.1=(0,fy,0), columns.2=(cx,cy,1)
        let intrinsics = leftSample.parameters.intrinsics
        if intrinsics[0][0] > 10 {
            currentIntrinsics = intrinsics
            print("[标定] ✓ 内参读取成功  fx=\(intrinsics[0][0])  fy=\(intrinsics[1][1])"
                  + "  cx=\(intrinsics[2][0])  cy=\(intrinsics[2][1])")
        } else {
            let w = Float(CVPixelBufferGetWidth(leftSample.pixelBuffer))
            print("[标定] ✗ 内参为零，将用估算 fx（图宽=\(Int(w)), 假设水平 FOV=100°）")
        }

        // 2. 基线：从左右外参的平移分量之差计算
        //    extrinsics 为相机到设备坐标系的变换矩阵，columns.3 为平移向量
        let leftTrans  = leftSample.parameters.extrinsics.columns.3
        let rightTrans = rightSample.parameters.extrinsics.columns.3
        let diff = simd_float3(rightTrans.x - leftTrans.x,
                               rightTrans.y - leftTrans.y,
                               rightTrans.z - leftTrans.z)
        let measuredBaseline = simd_length(diff)
        if measuredBaseline > 0.001 {
            actualBaseline = measuredBaseline
            print("[标定] ✓ 基线从外参计算: \(Int(measuredBaseline * 1000))mm")
        } else {
            print("[标定] 外参基线为零，保持默认 \(Int(actualBaseline * 1000))mm")
        }
    }

    /// 对当前所有左摄像头检测框计算相对距离并更新 objectDepths / objectDistanceMeters
    func updateObjectDepths() {
        guard !rawDepthValues.isEmpty, depthMaxVal > depthMinVal else {
            objectDepths = Array(repeating: nil, count: boundingBoxesLeft.count)
            objectDistanceMeters = Array(repeating: nil, count: boundingBoxesLeft.count)
            return
        }
        let infos = boundingBoxesLeft.map { depthInfo(for: $0) }
        objectDepths = infos.map { $0.0 }
        objectDistanceMeters = infos.map { $0.1 }
    }

    /// 在检测框内部采样 3×3 网格取中位深度，返回 (相对距离 0=近 1=远, 估算距离米)
    /// 模型输出深度值（值越小越近），坐标越界返回 (nil, nil)
    private func depthInfo(for box: CGRect) -> (Float?, Float?) {
        guard cameraImageSize != .zero else { return (nil, nil) }

        let camW = Float(cameraImageSize.width)
        let camH = Float(cameraImageSize.height)

        // 在检测框中心 60% 区域均匀采样 3×3，避免边缘噪声
        var samples: [Float] = []
        let offsets: [Float] = [0.25, 0.5, 0.75]
        for sx in offsets {
            for sy in offsets {
                // Vision 归一化坐标（原点左下角）→ 像素坐标（原点左上角，翻转 Y 轴）
                let normX = Float(box.origin.x) + Float(box.width) * sx
                let normY = Float(box.origin.y) + Float(box.height) * sy
                let pixX = normX * camW
                let pixY = (1.0 - normY) * camH

                // 像素坐标 → 深度图坐标（经裁剪 + 缩放映射到 512×512）
                let depX = (pixX - Float(depthCropX)) * depthScaleFactor
                let depY = (pixY - Float(depthCropY)) * depthScaleFactor

                guard depX >= 0 && depX < Float(depthModelSize) &&
                      depY >= 0 && depY < Float(depthModelHeight) else { continue }
                samples.append(rawDepthValues[Int(depY) * depthModelSize + Int(depX)])
            }
        }

        guard !samples.isEmpty else { return (nil, nil) }

        // 取中位数提高鲁棒性
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]

        // 修正方向：模型输出深度（值越小越近），直接归一化，0=近 1=远
        let normalized = (median - depthMinVal) / (depthMaxVal - depthMinVal)

        // 估算实际距离
        let distanceMeters: Float? = {
            if depthSource == .monocular {
                // 单目：无绝对基准，线性映射到经验范围 [0.30m, 8.00m]
                // normalized=0(近)→0.30m, normalized=1(远)→8.00m
                let est = 0.30 + normalized * (8.00 - 0.30)
                return est
            }
            // 双目：立体视觉公式 depth = fx * baseline / disparity
            // disparity（原始图像像素）≈ abs(median) / depthScaleFactor

            let absDisparity = abs(median) / depthScaleFactor
            guard absDisparity > 0.1, depthScaleFactor > 0 else { return nil }

            // 焦距：优先使用 ARKit 内参；否则根据图像宽度估算（假设水平 FOV ≈ 100°）
            let fx: Float
            if currentIntrinsics[0][0] > 10 {
                fx = currentIntrinsics[0][0]
            } else {
                fx = camW / (2.0 * tan(50.0 * .pi / 180.0))
            }

            let d = fx * actualBaseline / absDisparity
            guard d > 0.05 && d < 30.0 else { return nil }
            return d
        }()

        return (normalized, distanceMeters)
    }

    func startSession() async {
        // 检查企业许可证
        checkLicenseStatus()
        guard isLicenseValid, isCameraEntitled else {
            print("企业许可证检查未通过，无法使用摄像头功能")
            return
        }

        guard CameraFrameProvider.isSupported else {
            print("设备不支持主摄像头")
            return
        }

        // 初始化深度模型
        initializeDepthModel()

        await requestCameraAccess()
        guard cameraAccessAuthorizationStatus == .allowed else {
            print("用户未授权摄像头访问")
            return
        }
        let formats = CameraVideoFormat.supportedVideoFormats(for: .main, cameraPositions: [.left, .right])
        guard let selectedFormat = formats.first else {
            print("未找到支持的摄像头视频格式")
            return
        }

        let cameraFrameProvider = CameraFrameProvider()

        print("请求摄像头授权...")

        let authorizationResult = await arKitSession.requestAuthorization(for: [.cameraAccess])

        cameraAccessAuthorizationStatus = authorizationResult[.cameraAccess] ?? .notDetermined

        guard cameraAccessAuthorizationStatus == .allowed else {
            print("摄像头数据访问授权失败")
            return
        }

        print("摄像头授权成功，启动 ARKit 会话...")

        try? await arKitSession.run([cameraFrameProvider, worldTracking])

        print("ARKit 会话正在运行")

        guard let cameraFrameUpdates = cameraFrameProvider.cameraFrameUpdates(for: selectedFormat) else {
            print("无法获取摄像头帧更新")
            return
        }

        print("成功获取摄像头帧更新")

        // 添加帧率控制
        var lastProcessTime = Date()
        let minFrameInterval: TimeInterval = 1.0 / 30.0 // 限制最大帧率为30fps

        for await cameraFrame in cameraFrameUpdates {
            let currentTime = Date()
            let timeSinceLastProcess = currentTime.timeIntervalSince(lastProcessTime)
            
            // 如果距离上次处理时间太短，跳过这一帧
            if timeSinceLastProcess < minFrameInterval {
                continue
            }
            
            lastProcessTime = currentTime

            let samples = cameraFrame.samples
            let leftSample = samples.filter {
                return $0.parameters.cameraPosition == .left
            }
            let rightSample = samples.filter {
                return $0.parameters.cameraPosition == .right
            }
            
            // 处理左摄像头
            if !leftSample.isEmpty {
                self.pixelBufferLeft = leftSample[0].pixelBuffer
                self.capturedImageLeft = self.convertToUIImage(pixelBuffer: self.pixelBufferLeft)

                // 记录摄像头分辨率（用于麻将检测坐标换算）
                if let pb = self.pixelBufferLeft {
                    let w = CVPixelBufferGetWidth(pb)
                    let h = CVPixelBufferGetHeight(pb)
                    if self.cameraImageSize == .zero {
                        self.cameraImageSize = CGSize(width: w, height: h)
                    }
                }

                // Spatial YOLO / AI Live 模式：左摄像头 yolo11n 检测
                if activeFeature == .spatialYOLO || activeFeature == .geminiLive {
                    let leftBuffer = self.pixelBufferLeft!
                    let leftRequests = self.requestsLeft
                    Task.detached {
                        let handler = VNImageRequestHandler(cvPixelBuffer: leftBuffer)
                        try? handler.perform(leftRequests)
                    }
                }

                // 麻将模式：麻将牌 YOLO 检测
                if activeFeature == .mahjong {
                    let leftBuffer = self.pixelBufferLeft!
                    let mahjongRequests = self.requestsMahjong
                    Task.detached {
                        let handler = VNImageRequestHandler(cvPixelBuffer: leftBuffer)
                        try? handler.perform(mahjongRequests)
                    }
                }
            }

            // Spatial YOLO 模式：处理右摄像头 + 深度估计
            if activeFeature == .spatialYOLO {
                if !rightSample.isEmpty {
                    self.pixelBufferRight = rightSample[0].pixelBuffer
                    self.capturedImageRight = self.convertToUIImage(pixelBuffer: self.pixelBufferRight)

                    // 首帧捕获相机标定参数（内参 + 基线）
                    if !self.hasCalibration {
                        self.captureCalibration(leftSample: leftSample[0], rightSample: rightSample[0])
                    }

                    let rightBuffer = self.pixelBufferRight!
                    let rightRequests = self.requestsRight
                    Task.detached {
                        let handler = VNImageRequestHandler(cvPixelBuffer: rightBuffer)
                        try? handler.perform(rightRequests)
                    }
                }

                // 深度估计：双目需要左右都有数据；单目只需左摄像头
                let canRunDepth: Bool
                switch depthSource {
                case .stereo:    canRunDepth = !leftSample.isEmpty && !rightSample.isEmpty
                case .monocular: canRunDepth = !leftSample.isEmpty
                }
                if canRunDepth {
                    await processDepthEstimation()
                }
            }

            // Gemini Live / 麻将模式：定时采样帧发送给 AI 服务
            // geminiLive: 2 秒/帧，mahjong: 5 秒/帧（麻将牌静止，降低带宽）
            if (activeFeature == .geminiLive || activeFeature == .mahjong),
               isGeminiActive, let leftBuffer = self.pixelBufferLeft {
                let frameInterval: TimeInterval = (activeFeature == .mahjong) ? 5.0 : 2.0
                let timeSinceLastGemini = currentTime.timeIntervalSince(lastGeminiSendTime)
                if timeSinceLastGemini >= frameInterval {
                    lastGeminiSendTime = currentTime
                    print("[帧采样] 发送视频帧 (间隔\(Int(frameInterval))s, 模式:\(activeFeature))")
                    sendFrameToGemini(leftBuffer)
                }
            }
        }
    }

    private func requestCameraAccess() async {

        let authorizationResult = await arKitSession.requestAuthorization(for: [.cameraAccess])

        cameraAccessAuthorizationStatus = authorizationResult[.cameraAccess] ?? .notDetermined

        if cameraAccessAuthorizationStatus == .allowed {

            print("用户授权摄像头访问")

        } else {

            print("用户拒绝摄像头访问")

        }

    }

    private func convertToUIImage(pixelBuffer: CVPixelBuffer?) -> UIImage? {

        guard let pixelBuffer = pixelBuffer else {
            print("像素缓冲区为空")
            return nil
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
            return UIImage(cgImage: cgImage)
        }
        
        print("无法创建 CGImage")
        return nil
    }
    
}

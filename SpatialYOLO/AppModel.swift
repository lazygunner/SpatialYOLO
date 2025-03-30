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
        
    var selectedTab = 0
    
    var arKitSession = ARKitSession()
    var worldTracking = WorldTrackingProvider()

    var capturedImage: UIImage?

    private var pixelBuffer: CVPixelBuffer?

    private var cameraAccessAuthorizationStatus = ARKitSession.AuthorizationStatus.notDetermined
    var panelAttachment: Entity = Entity()
    // ARKit Hand Tracking
    var handTrackingPermitted = false
    var showARTryOnInstruction = true
    
    var instructionAttachment: Entity = Entity()
    
    // Vision parts
    var requests = [VNRequest]()
    var bufferSize: CGSize = .zero
    var boundingBoxes: [CGRect] = []
    var detectedClasses: [String] = []
    var confidences: [Float] = []
    var classNames: [String] = []
    
    var currentIntrinsics: simd_float3x3 = simd_float3x3(.zero)
    var currentExtrinsics: simd_float4x4 = simd_float4x4(.zero)
    var deviceTransform: Transform = Transform()
    var trackingPoint: SIMD3<Float> = .zero
    var trackingEnt = Entity()
    
    var imageCropOption: VNImageCropAndScaleOption = .scaleFit


    
    func startSession() async {
        guard CameraFrameProvider.isSupported else {
            print("Device does not support main camera")
            return
        }

        await requestCameraAccess()
        guard cameraAccessAuthorizationStatus == .allowed else {
            print("User did not authorize camera access")
            return
        }

        let formats = CameraVideoFormat.supportedVideoFormats(for: .main, cameraPositions: [.left])
        let cameraFrameProvider = CameraFrameProvider()

        print("Requesting camera authorization...")

        let authorizationResult = await arKitSession.requestAuthorization(for: [.cameraAccess])

        cameraAccessAuthorizationStatus = authorizationResult[.cameraAccess] ?? .notDetermined

        guard cameraAccessAuthorizationStatus == .allowed else {
            print("Camera data access authorization failed")
            return
        }

        print("Camera authorization successful, starting ARKit session...")
        
        try? await arKitSession.run([cameraFrameProvider, worldTracking])

        print("ARKit session is running")

        guard let cameraFrameUpdates = cameraFrameProvider.cameraFrameUpdates(for: formats[0]) else {
            print("Unable to get camera frame updates")
            return
        }

        print("Successfully got camera frame updates")

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

            guard let mainCameraSample = cameraFrame.sample(for: .left) else {
                print("Unable to get main camera sample")
                continue
            }

            self.pixelBuffer = mainCameraSample.pixelBuffer
            
            let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: self.pixelBuffer!)
            
            do {
                try imageRequestHandler.perform(self.requests)
            } catch {
                print(error)
            }
            
            self.capturedImage = self.convertToUIImage(pixelBuffer: self.pixelBuffer)
        }
    }

    private func requestCameraAccess() async {

        let authorizationResult = await arKitSession.requestAuthorization(for: [.cameraAccess])

        cameraAccessAuthorizationStatus = authorizationResult[.cameraAccess] ?? .notDetermined

        if cameraAccessAuthorizationStatus == .allowed {

            print("User granted camera access")

        } else {

            print("User denied camera access")

        }

    }

    private func convertToUIImage(pixelBuffer: CVPixelBuffer?) -> UIImage? {

        guard let pixelBuffer = pixelBuffer else {

            print("Pixel buffer is nil")

            return nil

        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        // print("ciImageSize:\(ciImage.extent.size)")

        let context = CIContext()

        if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {

            return UIImage(cgImage: cgImage)

        }

        print("Unable to create CGImage")

        return nil

    }
    
}

// 假设世界坐标系的 z = 0
// 假设世界坐标系的 z = 0
func unproject(points: [simd_float2],
               extrinsics: simd_float4x4,
               intrinsics: simd_float3x3) -> [simd_float3] {

    // 提取旋转矩阵和平移向量
    let rotation = simd_float3x3(
        simd_float3(extrinsics.columns.0.x, extrinsics.columns.0.y, extrinsics.columns.0.z), // 第一列的前三个分量
        simd_float3(extrinsics.columns.1.x, extrinsics.columns.1.y, extrinsics.columns.1.z), // 第二列的前三个分量
        simd_float3(extrinsics.columns.2.x, extrinsics.columns.2.y, extrinsics.columns.2.z)  // 第三列的前三个分量
    )

    let translation = simd_float3(extrinsics.columns.3.x, extrinsics.columns.3.y, extrinsics.columns.3.z) // 提取平移向量

    // 结果保存 3D 世界坐标
    var world_points = [simd_float3](repeating: simd_float3(0, 0, 0), count: points.count)

    // 计算内参矩阵的逆矩阵，用于将图像点投影到相机坐标系
    let inverseIntrinsics = intrinsics.inverse

    for i in 0..<points.count {
        let point = points[i]
        
        // 将 2D 图像点转换为 归一化相机坐标系中的 3D 点（假设 z = 1 的归一化坐标系下）
        let normalized_camera_point = inverseIntrinsics * simd_float3(point.x, point.y, 1.0)

        // 现在 z = 0.5，因此使用 z = 0.5 代替 z = 0 来解方程
        let scale = (0.5 - translation.z) / (rotation[2, 0] * normalized_camera_point.x +
                                             rotation[2, 1] * normalized_camera_point.y +
                                             rotation[2, 2])
        
        // 使用尺度因子将相机坐标系下的点投影到世界坐标系中
        let world_point_camera_space = scale * normalized_camera_point

        // 将相机坐标系中的点转换为世界坐标系
        let world_point = rotation.inverse * (world_point_camera_space - translation)

        world_points[i] = simd_float3(world_point.x, world_point.y, 0.5)  // 世界坐标系中的 z = 0.5

        print("intrinsics:\(intrinsics)")
        print("extrinsics:\(extrinsics)")
        let trans = Transform(matrix: extrinsics)
        print("extrinsics transform\(trans)")
        print("image point \(point) -> world point \(world_points[i])")
    }

    return world_points
}

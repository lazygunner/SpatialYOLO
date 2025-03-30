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
        let context = CIContext()
        if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
            return UIImage(cgImage: cgImage)
        }
        
        print("Unable to create CGImage")
        return nil
    }
    
}
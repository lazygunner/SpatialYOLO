//
//  AppModel+GeminiLive.swift
//  SpatialYOLO
//
//  Created by Claude on 2025/4/14.
//

import Foundation
import CoreImage
import UIKit

extension AppModel {

    /// 启动 Gemini Live 会话
    func startGeminiSession() {
        guard !isGeminiActive else { return }
        isGeminiActive = true
        geminiService.connect()
    }

    /// 停止 Gemini Live 会话
    func stopGeminiSession() {
        isGeminiActive = false
        geminiService.disconnect()
    }

    /// 切换 Gemini Live 会话状态
    func toggleGeminiSession() {
        if isGeminiActive {
            stopGeminiSession()
        } else {
            startGeminiSession()
        }
    }

    /// 将摄像头帧发送给 Gemini（1fps 采样，在帧循环中调用）
    /// 压缩和发送在后台线程执行，不阻塞主线程帧循环
    func sendFrameToGemini(_ pixelBuffer: CVPixelBuffer) {
        guard isGeminiActive,
              geminiService.connectionState == .connected else { return }

        // CIImage 是轻量惰性对象，主线程创建安全且会 retain pixelBuffer
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let service = self.geminiService

        // 重型压缩工作放到后台线程
        Task.detached {
            let context = CIContext()
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }

            let originalWidth = CGFloat(cgImage.width)
            let originalHeight = CGFloat(cgImage.height)
            let maxDimension: CGFloat = 1024
            let scale = min(maxDimension / originalWidth, maxDimension / originalHeight, 1.0)
            let targetWidth = Int(originalWidth * scale)
            let targetHeight = Int(originalHeight * scale)

            // CGContext 线程安全的缩放
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return }

            ctx.interpolationQuality = .medium
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

            guard let resizedCGImage = ctx.makeImage(),
                  let jpegData = UIImage(cgImage: resizedCGImage).jpegData(compressionQuality: 0.8) else { return }

            service.sendVideoFrame(jpegData: jpegData)
        }
    }

    /// 发送用户提问
    func sendUserQuestion(_ text: String) {
        guard !text.isEmpty,
              isGeminiActive,
              geminiService.connectionState == .connected else { return }

        geminiService.sendTextMessage(text)
        userInputText = ""
    }

}

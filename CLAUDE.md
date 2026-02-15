# SpatialYOLO - Project Guide

## Project Overview

Apple Vision Pro 应用，在沉浸式空间中使用 YOLOv11n 进行实时物体检测，并集成 Gemini Live API 实现交互式 AI 视觉助手。通过 ARKit 捕获摄像头画面，使用 CoreML + Vision 框架进行推理，在混合现实环境中叠加渲染检测结果（边界框 + 标签 + 置信度）。同时将画面实时发送至 Gemini Live，用户可基于当前画面向 AI 提问，AI 以文字+语音回复。

## Tech Stack

- **Language:** Swift 5.0 (Swift Tools 6.0 for packages)
- **Platform:** visionOS (Apple Vision Pro)
- **UI:** SwiftUI + RealityKit
- **AR:** ARKit (WorldTrackingProvider, CameraFrameProvider)
- **ML:** CoreML + Vision (VNCoreMLRequest)
- **AI:** Gemini Live API (WebSocket, 实时多模态)
- **Audio:** AVAudioEngine (PCM 音频播放)
- **Build:** Xcode 16.2, Swift Package Manager
- **Bundle ID:** com.darkstring.SpatialYOLO

## Architecture

MVVM 模式：

- **AppModel** (`@Observable`, `@MainActor`) — 核心状态管理，ARKit 会话、摄像头帧捕获、Vision 请求
- **AppModel+ObjectDetection** — ML 推理扩展，YOLO 模型加载、边界框提取（置信度阈值 0.5）
- **AppModel+GeminiLive** — Gemini 集成扩展，帧压缩发送、会话管理
- **GeminiLiveService** (`@Observable`) — WebSocket 通信服务，连接/发送/接收/音频播放
- **Views:** ContentView → ImmersiveView → CameraView/BoundingBoxOverlay + GeminiResponseView
- **Data Flow:**
  - YOLO: Camera → ARKit (30fps) → Vision → CoreML → Results → View
  - Gemini: Camera → ARKit (1fps采样) → JPEG压缩 → Base64 → WebSocket → Gemini → 文字/音频 → View

## Project Structure

```
SpatialYOLO/
├── SpatialYOLOApp.swift          # App 入口，场景管理
├── AppModel.swift                # 核心状态管理 (168 lines)
├── AppModel+ObjectDetection.swift # ML 推理扩展
├── AppModel+GeminiLive.swift     # Gemini 集成扩展
├── GeminiLiveService.swift       # Gemini WebSocket 通信服务
├── ContentView.swift             # 主窗口视图
├── ImmersiveView.swift           # 沉浸式空间 + RealityView
├── CameraView.swift              # 检测结果可视化 + 边界框
├── GeminiResponseView.swift      # Gemini 响应面板 UI
├── ToggleImmersiveSpaceButton.swift # 空间切换按钮
├── Info.plist                    # 应用配置（摄像头权限描述）
└── SpatialYOLO.entitlements      # 权限（ARKit 主摄像头访问）
Packages/
└── RealityKitContent/            # RealityKit 3D 资产包
doc/                              # 文档截图
```

## Key Patterns & Conventions

- **命名:** PascalCase (类型), camelCase (变量/方法)
- **扩展文件:** `ClassName+Feature.swift` 格式
- **并发:** async/await + @MainActor 保证主线程安全
- **UI 更新:** Vision 回调中使用 DispatchQueue.main
- **帧率控制:** YOLO 30fps, Gemini 1fps（独立采样计时器）
- **注释:** 中文为主

## ML Models

- **yolo11n.mlpackage** — YOLOv11 Nano 物体检测（活跃使用）
- **RaftStereo512.mlpackage** — 立体深度估计（预留，未启用）

## Build & Run

需要 Xcode 16.2+，visionOS SDK。需要企业证书（主摄像头访问权限）。

```bash
# 通过 Xcode 打开项目
open SpatialYOLO.xcodeproj
# 选择 visionOS 模拟器或真机运行
```

## Gemini Live API

- **端点:** `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent`
- **模型:** `gemini-2.5-flash-preview-native-audio-dialog`
- **视频帧:** 1fps, JPEG, 768x768, base64 编码
- **音频输出:** 24kHz, 16-bit PCM, mono
- **会话限制:** 视频+音频 2 分钟，音频 15 分钟，上下文 128k tokens
- **认证:** API Key (需在 AppModel.swift 中配置 `YOUR_API_KEY`)

## Dependencies

仅依赖 Apple 原生框架，无第三方外部依赖。唯一本地包：RealityKitContent。

## Testing

当前无测试基础设施。

## Git Conventions

- 分支：main (生产), gemini-live (开发)
- Commit 前缀：`feat:`, `fix:` 等
- .gitignore 排除：.mlpackage, Build/, license 文件

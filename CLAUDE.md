# SpatialYOLO - Project Guide

## Project Overview

Apple Vision Pro 应用，包含两大功能模块：
1. **Spatial YOLO** — 双目摄像头 + YOLOv11n 实时物体检测 + RaftStereo512 立体深度估计
2. **Gemini Live** — 集成 Google Gemini Live API 的交互式 AI 视觉助手，支持实时视频流 + 语音双向对话

通过 ARKit 捕获双目摄像头画面，使用 CoreML + Vision 框架进行推理，在混合现实环境中叠加渲染检测结果。Gemini Live 模式将画面和麦克风音频实时发送至 Gemini，AI 以语音+字幕回复。

## Tech Stack

- **Language:** Swift 5.0 (Swift Tools 6.0 for packages)
- **Platform:** visionOS (Apple Vision Pro)
- **UI:** SwiftUI + RealityKit
- **AR:** ARKit (WorldTrackingProvider, CameraFrameProvider)
- **ML:** CoreML + Vision (VNCoreMLRequest)
- **AI:** Gemini Live API (WebSocket, 实时多模态双向通信)
- **Audio:** AVAudioEngine (PCM 录制 16kHz + 播放 24kHz)
- **Build:** Xcode 16.2, Swift Package Manager
- **Bundle ID:** com.darkstring.SpatialYOLO

## Architecture

MVVM 模式，双功能模块切换：

- **AppModel** (`@Observable`, `@MainActor`) — 核心状态管理，`FeatureMode` 切换，ARKit 会话、双目摄像头帧捕获、企业许可证检查
- **AppModel+ObjectDetection** — YOLO 推理扩展，左右摄像头分别检测，边界框提取（置信度阈值 0.5）
- **AppModel+GeminiLive** — Gemini 集成扩展，帧压缩发送（后台线程 `Task.detached`），会话管理
- **GeminiLiveService** (`@Observable`) — WebSocket 通信服务，连接/发送/接收/音频录制+播放
- **Views:**
  - ContentView — 功能选择主页（Liquid Glass 风格双卡片）
  - ImmersiveView — 沉浸式空间 RealityView，按 `activeFeature` 条件布局
  - CameraView — DualCameraView / DepthView / BoundingBoxOverlay
  - GeminiResponseView — Gemini 控制面板（状态/输入/启停）
  - GeminiSubtitleOverlay — 字幕叠加层（打字机效果）
- **Data Flow:**
  - YOLO: Camera → ARKit (30fps) → Vision → CoreML (后台线程) → Results → View
  - Gemini 视频: Camera → ARKit (1fps采样) → JPEG压缩 (后台线程, max 1024px) → Base64 → WebSocket → Gemini
  - Gemini 音频: 麦克风 → AVAudioEngine (16kHz PCM) → Base64 → WebSocket → Gemini
  - Gemini 响应: WebSocket → 音频 (24kHz PCM → 播放) + 文字 (thought → 字幕)

## Project Structure

```
SpatialYOLO/
├── SpatialYOLOApp.swift              # App 入口，场景管理
├── AppModel.swift                    # 核心状态管理，FeatureMode，企业许可证
├── AppModel+ObjectDetection.swift    # YOLO 推理扩展（左右摄像头）
├── AppModel+GeminiLive.swift         # Gemini 集成扩展（帧压缩/会话管理）
├── GeminiLiveService.swift           # Gemini WebSocket 通信 + 音频录制/播放
├── ContentView.swift                 # 主窗口（Liquid Glass 双功能卡片）
├── ImmersiveView.swift               # 沉浸式空间 RealityView
├── CameraView.swift                  # 双目摄像头/深度图/边界框可视化
├── GeminiResponseView.swift          # Gemini 控制面板 UI
├── GeminiSubtitleOverlay.swift       # Gemini 字幕叠加（打字机效果）
├── ToggleImmersiveSpaceButton.swift  # 空间切换按钮
├── Config.plist                      # API Key 配置（gitignored）
├── Config.plist.example              # 配置模板
├── Info.plist                        # 应用配置（摄像头/麦克风权限）
└── SpatialYOLO.entitlements          # 权限（ARKit 主摄像头访问）
Packages/
└── RealityKitContent/                # RealityKit 3D 资产包
doc/
├── live-api-video.md                 # Gemini Live API Python 参考实现
└── *.png                             # 文档截图
```

## Key Patterns & Conventions

- **命名:** PascalCase (类型), camelCase (变量/方法)
- **扩展文件:** `ClassName+Feature.swift` 格式
- **并发:** async/await + @MainActor 保证主线程安全
- **后台处理:** YOLO `perform()` 和 Gemini 帧压缩使用 `Task.detached` 避免阻塞主线程
- **UI 更新:** Vision 回调中使用 DispatchQueue.main
- **帧率控制:** YOLO 30fps, Gemini 视频 1fps（独立采样计时器）
- **功能隔离:** `FeatureMode` 枚举控制，Spatial YOLO 模式跳过 Gemini 帧发送，Gemini 模式跳过右摄像头和深度估计
- **注释:** 中文为主

## ML Models

- **yolo11n.mlpackage** — YOLOv11 Nano 物体检测（80 类 COCO）
- **RaftStereo512.mlpackage** — RAFT 立体深度估计（512x512 输入）

## Configuration

### API Key 配置

Gemini API Key 通过 `Config.plist` 文件配置，不硬编码在代码中：

1. 复制模板文件：`cp SpatialYOLO/Config.plist.example SpatialYOLO/Config.plist`
2. 编辑 `Config.plist`，将 `YOUR_API_KEY_HERE` 替换为你的 Gemini API Key
3. 在 Xcode 中将 `Config.plist` 添加到项目的 Build Resources
4. `Config.plist` 已在 `.gitignore` 中，不会被提交

### 企业许可证

需要 Apple Enterprise API 许可证（`*.license` 文件），用于主摄像头访问权限。

## Build & Run

需要 Xcode 16.2+，visionOS SDK。需要企业证书（主摄像头访问权限）。

```bash
# 1. 配置 API Key
cp SpatialYOLO/Config.plist.example SpatialYOLO/Config.plist
# 编辑 Config.plist 填入 Gemini API Key

# 2. 通过 Xcode 打开项目
open SpatialYOLO.xcodeproj

# 3. 选择 visionOS 真机运行（需企业证书）
```

## Gemini Live API

- **端点:** `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent`
- **模型:** `gemini-2.5-flash-native-audio-preview-12-2025`（Native Audio）
- **视频帧:** 1fps, JPEG, thumbnail max 1024px (保持宽高比), quality 0.8, base64
- **音频输入:** 16kHz, 16-bit PCM, mono（麦克风 → AVAudioConverter → WebSocket）
- **音频输出:** 24kHz, 16-bit PCM, mono（WebSocket → AVAudioPlayerNode）
- **响应格式:** `responseModalities: ["AUDIO"]` + `outputAudioTranscription`
- **字幕来源:** thought 部分的 text 字段（模型推理文本）
- **会话限制:** 视频+音频约 2 分钟
- **认证:** API Key（通过 `Config.plist` 配置）
- **Voice:** Zephyr (prebuiltVoiceConfig)

## Dependencies

仅依赖 Apple 原生框架，无第三方外部依赖。唯一本地包：RealityKitContent。

## Testing

当前无测试基础设施。

## Git Conventions

- 分支：main (生产), gemini-live (开发)
- Commit 前缀：`feat:`, `fix:` 等
- .gitignore 排除：.mlpackage, Build/, license 文件, Config.plist
- API Key 等敏感信息禁止提交，使用 Config.plist 配置

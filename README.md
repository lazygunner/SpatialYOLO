[English](README.md) | [中文](README_zh.md)

# SpatialYOLO

Real-time object detection and AI visual assistant on Apple Vision Pro.

- **Spatial YOLO** — Stereo camera + YOLOv11n object detection + stereo depth estimation
- **AI Live** — Interactive AI assistant with real-time video + voice conversation, supports Google Gemini Live and Alibaba Qwen Omni

## I. Generate YOLO Model Supported by CoreML
### 1. Install ultralytics
If you haven't installed the ultralytics library, install it first using the command
```
pip install ultralytics
```
### 2. Select Model
![](doc/1.png)

Here we choose yolo11n because it has a small model size and fast speed.
### 3. Export to CoreML Supported Format
```
yolo export model=yolo11n.pt format=coreml nms=true
```
![](doc/2.png)
### 4. Add yolo11n.mlpackage to Project
![](doc/3.png)

Reference Documentation
https://docs.ultralytics.com/integrations/coreml/

## II. Enterprise Certificate and Capability Settings
### 1. Add Certificate
![](doc/4.png)

This certificate is sent by Apple via email after successful enterprise API application
### 2. Set Capability
![](doc/5.png)

On the Signing & Capabilities page, click the + Capability button, which will open a search interface. Search for Main Camera Access, then double-click to add it to the project.

![](doc/6.png)

After that, an entitlement file with a yellow icon will appear

![](doc/7.png)

## III. AI Live API Configuration

### 1. Get API Keys
- **Gemini:** Obtain a Gemini API Key from [Google AI Studio](https://aistudio.google.com/)
- **Qwen:** Obtain a DashScope API Key from [Alibaba Cloud Bailian](https://bailian.console.aliyun.com/)

### 2. Configure API Keys
```bash
# Copy the template config file
cp SpatialYOLO/Config.plist.example SpatialYOLO/Config.plist
```

Edit `SpatialYOLO/Config.plist` and replace `YOUR_API_KEY_HERE` with your actual API Keys:
```xml
<key>GEMINI_API_KEY</key>
<string>your-gemini-api-key</string>
<key>QWEN_API_KEY</key>
<string>your-qwen-api-key</string>
```

### 3. Add Config.plist to Xcode Project
Add `Config.plist` to the Xcode project's target build resources so it can be read at runtime via `Bundle.main`.

> **Note:** `Config.plist` is in `.gitignore` and will not be committed to the repository.

### 4. Supported AI Providers

**Gemini Live** (Google)
- **Model:** `gemini-2.5-flash-native-audio-preview-12-2025` (Native Audio)
- **Session Limit:** ~2 minutes for video + audio sessions

**Qwen Omni** (Alibaba)
- **Model:** `qwen3-omni-flash-realtime`
- **Session Limit:** 120 minutes
- **Server VAD:** Auto-detect speech start/stop
- **Native Chinese:** Reliable audio transcription in Chinese

**Common Features**
- **Real-time Video:** Camera frames sampled at 1fps, JPEG compressed (max 1024px), sent via WebSocket
- **Voice Input:** Microphone audio captured at 16kHz PCM, sent in real-time
- **Audio Response:** AI responds with PCM audio, played through AVAudioEngine
- **Subtitles:** AI response text displayed as typewriter-effect overlay on the video feed
- **Provider Switch:** Toggle between Gemini and Qwen in the control panel

## IV. Build & Run

Requirements: Xcode 16.2+, visionOS SDK, Apple Enterprise Certificate (for main camera access).

```bash
# 1. Configure API Keys (see section III)
cp SpatialYOLO/Config.plist.example SpatialYOLO/Config.plist

# 2. Open project in Xcode
open SpatialYOLO.xcodeproj

# 3. Select visionOS device and run
```

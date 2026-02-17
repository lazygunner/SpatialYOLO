[English](README.md) | [中文](README_zh.md)

# SpatialYOLO

Apple Vision Pro 上的实时物体检测与 AI 视觉助手。

- **Spatial YOLO** — 双目摄像头 + YOLOv11n 物体检测 + 立体深度估计
- **AI Live** — 交互式 AI 助手，支持实时视频 + 语音对话，兼容 Google Gemini Live 和阿里 Qwen Omni

## 一、生成 CoreML 支持的 YOLO 模型
### 1. 安装 ultralytics
如果没有安装过 ultralytics 库，先通过命令安装
```
pip install ultralytics
```
### 2. 选择模型
![](doc/1.png)

这里我们选择 yolo11n，因为模型体积小速度快。
### 3. 导出 CoreML 支持的格式
```
yolo export model=yolo11n.pt format=coreml nms=true
```
![](doc/2.png)
### 4. 添加 yolo11n.mlpackage 到项目
![](doc/3.png)

参考文档
https://docs.ultralytics.com/integrations/coreml/

## 二、企业证书和 Capability 设置
### 1. 添加证书
![](doc/4.png)

这个证书是企业 API 申请成功之后，苹果通过邮件发送的
### 2. 设置 Capability
![](doc/5.png)

在 Signing & Capabilities 页面，点击 + Capability 按钮，会弹出一个搜索界面，搜索 Main Camera Access，然后双击添加到项目中。

![](doc/6.png)

之后就会出现一个黄色图标的 entitlement 文件

![](doc/7.png)

## 三、AI Live API 配置

### 1. 获取 API Key
- **Gemini：** 从 [Google AI Studio](https://aistudio.google.com/) 获取 Gemini API Key
- **Qwen：** 从[阿里云百炼](https://bailian.console.aliyun.com/)获取 DashScope API Key

### 2. 配置 API Key
```bash
# 复制模板配置文件
cp SpatialYOLO/Config.plist.example SpatialYOLO/Config.plist
```

编辑 `SpatialYOLO/Config.plist`，将 `YOUR_API_KEY_HERE` 替换为你的 API Key：
```xml
<key>GEMINI_API_KEY</key>
<string>你的-gemini-api-key</string>
<key>QWEN_API_KEY</key>
<string>你的-qwen-api-key</string>
```

### 3. 将 Config.plist 添加到 Xcode 项目
将 `Config.plist` 添加到 Xcode 项目的 target build resources 中，以便运行时通过 `Bundle.main` 读取。

> **注意：** `Config.plist` 已加入 `.gitignore`，不会被提交到代码仓库。

### 4. 支持的 AI 服务商

**Gemini Live**（Google）
- **模型：** `gemini-2.5-flash-native-audio-preview-12-2025`（Native Audio）
- **会话时长：** 视频 + 音频会话约 2 分钟

**Qwen Omni**（阿里）
- **模型：** `qwen3-omni-flash-realtime`
- **会话时长：** 120 分钟
- **Server VAD：** 自动检测用户语音起止
- **原生中文：** 可靠的中文语音转录

**通用功能**
- **实时视频：** 摄像头画面以 1fps 采样，JPEG 压缩（最大 1024px），通过 WebSocket 发送
- **语音输入：** 麦克风音频以 16kHz PCM 采集，实时发送
- **语音回复：** AI 以 PCM 音频回复，通过 AVAudioEngine 播放
- **字幕：** AI 回复文字以打字机效果叠加显示在视频画面上
- **服务商切换：** 在控制面板中切换 Gemini 和 Qwen

## 四、构建与运行

环境要求：Xcode 16.2+、visionOS SDK、Apple 企业证书（用于主摄像头访问）。

```bash
# 1. 配置 API Key（参见第三节）
cp SpatialYOLO/Config.plist.example SpatialYOLO/Config.plist

# 2. 用 Xcode 打开项目
open SpatialYOLO.xcodeproj

# 3. 选择 visionOS 设备并运行
```

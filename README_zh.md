[English](README.md) | [中文](README_zh.md)

# SpatialYOLO

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-visionOS-blue)](https://developer.apple.com/visionos/)
[![Xcode](https://img.shields.io/badge/Xcode-16.2%2B-blue)](https://developer.apple.com/xcode/)

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

![](doc/Config.png)

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

## 四、OpenClaw 淘宝自动加购（可选）

OpenClaw 是一个可选的配套功能，让 AI Live 助手能通过分析摄像头画面，自动搜索商品并添加到淘宝购物车。

### 工作原理

1. Vision Pro 应用捕获摄像头帧，发送到 Mac 上运行的**工作区图片服务器**
2. 服务器接收图片后，启动本地 Node.js Playwright 脚本进行淘宝图搜，并将找到的商品加入购物车
3. 进度实时轮询并显示在 AI Live 控制面板中

### 启动工作区图片服务器（Mac 端）

```bash
# 安装依赖（首次运行）
cd scripts/taobao-image-search
npm install

# 启动服务器
OPENCLAW_TOKEN=your-token bash scripts/run_openclaw_workspace_image_server.sh
```

服务器默认监听 `http://0.0.0.0:18888`。

**关键环境变量：**

| 变量 | 默认值 | 说明 |
|---|---|---|
| `WORKSPACE_IMAGE_SERVER_PORT` | `18888` | HTTP 监听端口 |
| `OPENCLAW_TOKEN` | — | 共享认证 Token |
| `OPENCLAW_BASE_URL` | `http://127.0.0.1:18789` | OpenClaw 网关地址 |
| `OPENCLAW_IMAGE_PATH` | `~/.openclaw/workspace/image.png` | 图片上传保存路径 |
| `TAOBAO_IMAGE_SEARCH_HEADLESS` | `0` | 设置为 `1` 启用无头模式 |

**服务器接口：**

| 方法 | 路径 | 说明 |
|---|---|---|
| `GET` | `/health` | 健康检查 |
| `POST` | `/upload-image` | 接收来自 Vision Pro 的 JPEG 帧 |
| `POST` | `/tasks/openclaw` | 创建新的加购任务 |
| `GET` | `/tasks/:id` | 查询任务状态 |

### Vision Pro 端配置

在 `SpatialYOLO/Config.plist` 中添加以下配置项：

```xml
<key>OPENCLAW_UPLOAD_BASE_URL</key>
<string>http://your-mac-ip:18888</string>
<key>OPENCLAW_TOKEN</key>
<string>your-token</string>
```

### 淘宝登录

脚本使用 Playwright 保存的登录状态访问淘宝。首次运行时需要保存登录状态：

```bash
cd scripts/taobao-image-search
node save-taobao-cookie.js
```

按浏览器提示登录淘宝后，会话状态将被保存，后续运行无需重复登录。

## 五、构建与运行

环境要求：Xcode 16.2+、visionOS SDK、Apple 企业证书（用于主摄像头访问）。

```bash
# 1. 配置 API Key（参见第三节）
cp SpatialYOLO/Config.plist.example SpatialYOLO/Config.plist

# 2. 用 Xcode 打开项目
open SpatialYOLO.xcodeproj

# 3. 选择 visionOS 设备并运行
```

## 贡献

欢迎提交 Issue 和 Pull Request！

## 许可证

本项目采用 MIT 许可证，详见 [LICENSE](LICENSE)。

# Qwen Omni Realtime 对接方案

## 一、协议对比

| 维度 | Gemini Live (现有) | Qwen Omni Realtime |
|------|-------------------|-------------------|
| 协议 | WebSocket | WebSocket |
| 端点 | `wss://generativelanguage.googleapis.com/ws/...` | `wss://dashscope.aliyuncs.com/api-ws/v1/realtime` |
| 认证 | URL query `?key=API_KEY` | Header `Authorization: Bearer API_KEY` |
| 初始化 | 自定义 `setup` 消息 | OpenAI 兼容 `session.update` 事件 |
| 音频输入 | 16kHz PCM16 mono | 16kHz PCM16 mono（一致） |
| 音频输出 | 24kHz PCM16 | 24kHz PCM24 (flash) / 16kHz PCM16 (turbo) |
| 图像输入 | `realtimeInput.mediaChunks` (JPEG base64) | `input_image_buffer.append` (JPEG base64) |
| 文字输入 | `clientContent.turns` | `conversation.item.create` |
| 会话时长 | ~2 分钟 | 120 分钟 |
| VAD | 无（客户端控制） | 内置 server_vad |
| 中文支持 | system prompt 引导，thought 为英文 | 原生中文（含方言） |
| 转录 | `outputAudioTranscription`（当前未生效） | `response.audio_transcript.delta`（可靠） |

## 二、消息格式差异

### 初始化

```json
// Gemini: setup 消息
{
  "setup": {
    "model": "models/gemini-2.5-flash-native-audio-preview-12-2025",
    "generationConfig": { "responseModalities": ["AUDIO"] },
    "systemInstruction": { "parts": [{ "text": "..." }] }
  }
}

// Qwen: session.update 事件
{
  "type": "session.update",
  "session": {
    "modalities": ["text", "audio"],
    "voice": "Cherry",
    "input_audio_format": "pcm16",
    "output_audio_format": "pcm24",
    "instructions": "...",
    "turn_detection": { "type": "server_vad", "threshold": 0.5, "silence_duration_ms": 800 }
  }
}
```

### 发送图像

```json
// Gemini
{ "realtimeInput": { "mediaChunks": [{ "mimeType": "image/jpeg", "data": "base64..." }] } }

// Qwen
{ "type": "input_image_buffer.append", "image": "base64..." }
```

### 发送音频

```json
// Gemini
{ "realtimeInput": { "mediaChunks": [{ "mimeType": "audio/pcm", "data": "base64..." }] } }

// Qwen
{ "type": "input_audio_buffer.append", "audio": "base64..." }
```

### 接收响应

```
// Gemini: serverContent.modelTurn.parts[].inlineData / text / transcript
// Qwen:   response.audio.delta / response.audio_transcript.delta / response.text.delta
```

## 三、实现方案

### 架构

```
                    ┌─ GeminiLiveService  (现有)
AppModel ── protocol RealtimeAIService ──┤
                    └─ QwenOmniService    (新建)
```

### 新建文件

1. **`QwenOmniService.swift`** — WebSocket 通信核心，实现 RealtimeAIService 协议
2. **`RealtimeAIService.swift`** — 抽象协议定义

### 修改文件

3. **`AppModel.swift`** — 新增 `AIProvider` 枚举、`qwenService` 属性、Config.plist 读取 QWEN_API_KEY
4. **`AppModel+GeminiLive.swift`** — 改为通用 `sendFrameToAI`，根据 activeProvider 调用不同 service
5. **`GeminiLiveService.swift`** — 实现 RealtimeAIService 协议
6. **`GeminiResponseView.swift`** — 新增 provider 切换按钮
7. **`Config.plist.example`** — 新增 QWEN_API_KEY 字段

### 关键适配点

- **认证**：Qwen 用 `URLRequest` + `Authorization: Bearer` Header
- **PCM24 播放**：24-bit PCM → 16-bit 转换后播放
- **先发音频再发图像**：连接建立后先发一段静音 PCM
- **Server VAD**：Qwen 自动检测语音端点，无需客户端控制

## 四、Qwen 独特优势

- 会话时长 120 分钟 vs Gemini 2 分钟
- 原生中文 + 可靠音频转录（解决 Gemini 英文 thought 字幕问题）
- Server VAD 自动检测语音端点
- 49 种声音选择
- 免费额度：每个模态 100 万 token（90 天）

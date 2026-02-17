如何使用
1. 建立连接
Qwen-Omni-Realtime 模型通过 WebSocket 协议接入，可通过以下 Python 示例代码建立连接。也可通过DashScope SDK 建立连接。

说明
请注意，Qwen-Omni-Realtime 的单次 WebSocket 会话最长可持续 120 分钟。达到此上限后，服务将主动关闭连接。

WebSocket 原生连接DashScope SDK
连接时需要以下配置项：

配置项

说明

调用地址

中国内地（北京）：wss://dashscope.aliyuncs.com/api-ws/v1/realtime

国际（新加坡）：wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime

查询参数

查询参数为model，需指定为访问的模型名。示例：?model=qwen3-omni-flash-realtime

请求头

使用 Bearer Token 鉴权：Authorization: Bearer DASHSCOPE_API_KEY

DASHSCOPE_API_KEY 是您在百炼上申请的API Key。
 
# pip install websocket-client
import json
import websocket
import os

API_KEY=os.getenv("DASHSCOPE_API_KEY")
API_URL = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-omni-flash-realtime"

headers = [
    "Authorization: Bearer " + API_KEY
]

def on_open(ws):
    print(f"Connected to server: {API_URL}")
def on_message(ws, message):
    data = json.loads(message)
    print("Received event:", json.dumps(data, indent=2))
def on_error(ws, error):
    print("Error:", error)

ws = websocket.WebSocketApp(
    API_URL,
    header=headers,
    on_open=on_open,
    on_message=on_message,
    on_error=on_error
)

ws.run_forever()
2. 配置会话
发送客户端事件session.update：

 
{
    // 该事件的id，由客户端生成
    "event_id": "event_ToPZqeobitzUJnt3QqtWg",
    // 事件类型，固定为session.update
    "type": "session.update",
    // 会话配置
    "session": {
        // 输出模态，支持设置为["text"]（仅输出文本）或["text","audio"]（输出文本与音频）。
        "modalities": [
            "text",
            "audio"
        ],
        // 输出音频的音色
        "voice": "Cherry",
        // 输入音频格式，仅支持设为pcm16。
        "input_audio_format": "pcm16",
        // 输出音频格式，
        // Qwen3-Omni-Flash-Realtime：仅支持设置为pcm24、Qwen-Omni-Turbo-Realtime：仅支持设置为 pcm16
        "output_audio_format": "pcm24",
        // 系统消息，用于设定模型的目标或角色。
        "instructions": "你是某五星级酒店的AI客服专员，请准确且友好地解答客户关于房型、设施、价格、预订政策的咨询。请始终以专业和乐于助人的态度回应，杜绝提供未经证实或超出酒店服务范围的信息。",
        // 是否开启语音活动检测。若需启用，需传入一个配置对象，服务端将据此自动检测语音起止。
        // 设置为null表示由客户端决定何时发起模型响应。
        "turn_detection": {
            // VAD类型，需设置为server_vad。
            "type": "server_vad",
            // VAD检测阈值。建议在嘈杂的环境中增加，在安静的环境中降低。
            "threshold": 0.5,
            // 检测语音停止的静音持续时间，超过此值后会触发模型响应
            "silence_duration_ms": 800
        }
    }
}
3. 输入音频与图片
客户端通过input_audio_buffer.append和 input_image_buffer.append 事件发送 Base64 编码的音频和图片数据到服务端缓冲区。音频输入是必需的；图片输入是可选的。

图片可以来自本地文件，或从视频流中实时采集。
启用服务端VAD时，服务端会在检测到语音结束时自动提交数据并触发响应。禁用VAD时（手动模式），客户端必须在发送完数据后，主动调用input_audio_buffer.commit事件来提交。
4. 接收模型响应
模型的响应格式取决于配置的输出模态。

仅输出文本

通过response.text.delta事件接收流式文本，response.text.done事件获取完整文本。

输出文本+音频

文本：通过response.audio_transcript.delta事件接收流式文本，response.audio_transcript.done事件获取完整文本。

音频：通过response.audio.delta事件获取 Base64 编码的流式输出音频数据。response.audio.done事件标志音频数据生成完成。

适用范围
支持的地域
北京：需使用该地域的API Key

新加坡：需使用该地域的API Key

支持的模型
Qwen3-Omni-Flash-Realtime 是通义千问最新推出的实时多模态模型，相比于上一代的 Qwen-Omni-Turbo-Realtime（后续不再更新）：

支持的语言

增加至 10 种，包括汉语（支持普通话及多种主流方言，如上海话、粤语、四川话等）、英语，法语、德语、俄语、意大利语、西班牙语、葡萄牙语、日语、韩语，Qwen-Omni-Turbo-Realtime 仅支持 2 种（汉语（普通话）和英语）。

支持的音色

qwen3-omni-flash-realtime-2025-12-01支持的音色增加至49种，qwen3-omni-flash-realtime-2025-09-15、qwen3-omni-realtime-flash增加至 17 种，Qwen-Omni-Turbo-Realtime 仅支持 4 种；具体可查看音色列表。


将session.update事件的session.turn_detection 设为"server_vad"以启用 VAD 模式。此模式下，服务端自动检测语音起止并进行响应。适用于语音通话场景。

交互流程如下：

服务端检测到语音开始，发送input_audio_buffer.speech_started 事件。

客户端随时发送 input_audio_buffer.append与input_image_buffer.append 事件追加音频与图片至缓冲区。

发送 input_image_buffer.append 事件前，至少发送过一次 input_audio_buffer.append 事件。
服务端检测到语音结束，发送input_audio_buffer.speech_stopped 事件。

服务端发送input_audio_buffer.committed 事件提交音频缓冲区。

服务端发送 conversation.item.created 事件，包含从缓冲区创建的用户消息项。

生命周期

客户端事件

服务端事件

会话初始化

session.update

会话配置
session.created

会话已创建
session.updated

会话配置已更新
用户音频输入

input_audio_buffer.append

添加音频到缓冲区
input_image_buffer.append

添加图片到缓冲区
input_audio_buffer.speech_started

检测到语音开始
input_audio_buffer.speech_stopped

检测到语音结束
input_audio_buffer.committed

服务器收到提交的音频
服务器音频输出

无

response.created

服务端开始生成响应
response.output_item.added

响应时有新的输出内容
conversation.item.created

对话项被创建
response.content_part.added

新的输出内容添加到assistant message
response.audio_transcript.delta

增量生成的转录文字
response.audio.delta

模型增量生成的音频
response.audio_transcript.done

文本转录完成
response.audio.done

音频生成完成
response.content_part.done

Assistant message 的文本或音频内容流式输出完成
response.output_item.done

Assistant message 的整个输出项流式传输完成
response.done

响应完成
# OpenClaw 图片到淘宝加购链路整理

## 1. 背景

目标是从 Vision Pro 或自定义客户端发送一张商品图片，让 OpenClaw 基于图片在淘宝执行“以图搜同款 + 加入购物车”。

本次排查的核心问题不是淘宝自动化本身，而是：

- 如何把图片稳定送进 OpenClaw
- 如何让 OpenClaw 在执行 skill 时拿到正确的图片路径
- 如何避免长流程被 `curl` 超时提前截断

## 2. 结论

最终稳定可用的方案是：

1. 在 OpenClaw 所在机器运行一个本地图片上传服务
2. 将上传的图片固定写入：
   - `/Users/gunner/.openclaw/workspace/image.png`
3. 通过该服务异步提交 OpenClaw 任务
4. Vision Pro 端定时轮询任务状态
5. OpenClaw 基于该路径执行淘宝 skill

当前可直接使用的 prompt 形式：

```text
MEDIA:/Users/gunner/.openclaw/workspace/image.png 使用 skill淘宝搜索并加入购物车
```

该链路已经成功跑通，并拿到了“已加入购物车”的结果。

## 3. 本次踩坑总结

### 3.1 直接走 `/v1/chat/completions` 不稳定

- 该端点的可用性受网关开关影响
- 即使开启后，图片输入也不一定真正进入模型
- 在本次环境里，不适合作为稳定图片输入方案

### 3.2 直接走 `/v1/responses + input_image` 也不稳定

- 接口可以返回 `200`
- 但 `openclaw:main` 不一定真的“看到”图片
- 说明模型/agent 路由和图片输入之间存在实现差异

### 3.3 `chat.send + attachments` 不等价于原生聊天图片附件

- 通过 Gateway WS 自己构造 `chat.send`
- 虽然可以把 `attachments` 发出去
- 但在本次环境里，agent 最终仍然尝试去读取：
  - `/Users/gunner/.openclaw/workspace/image.png`
- 并报 `ENOENT`

### 3.4 聊天界面原生粘贴图片也会失败在“落盘”

- Control UI 的输入框支持 `paste images`
- 前端会显示 `Attachment preview`
- 但后端最终还是去读：
  - `/Users/gunner/.openclaw/workspace/image.png`
- 如果文件没有真正写进去，最终仍会失败

### 3.5 真正稳定的做法是绕过附件落盘逻辑

既然 OpenClaw 最终会去读固定路径：

- `/Users/gunner/.openclaw/workspace/image.png`

那最稳的做法就是：

- 由我们自己的上传服务直接把图片写到这个路径
- 再让 OpenClaw 读取这张图片

## 4. 本次新增脚本

### 4.0 Vision Pro 端集成

本次还将最终稳定方案接入到了 Vision Pro App 内：

- `SpatialYOLO/OpenClawService.swift`
  - 负责提交图片和 prompt 到异步任务服务
  - 轮询任务状态
- `SpatialYOLO/AppModel+OpenClaw.swift`
  - 负责关键词触发、任务提交与轮询
  - 使用 prompt：
    - `MEDIA:/Users/gunner/.openclaw/workspace/image.png 使用 skill淘宝搜索并加入购物车`
- `SpatialYOLO/AppModel+GeminiLive.swift`
  - 在 Gemini Live 压缩当前帧后，缓存最近的 JPEG
- `SpatialYOLO/AudioInputMonitor.swift`
  - 增加 transcript 变化回调
- `SpatialYOLO/GeminiResponseView.swift`
  - 增加“购物车 / CART”手动按钮
  - 展示任务缩略图和状态（处理中 / 已完成 / 失败）
- `SpatialYOLO/Config.plist.example`
  - 增加 OpenClaw 相关配置项
- `SpatialYOLO/Info.plist`
  - 增加局域网访问说明与本地网络 ATS 配置

### 4.1 图片上传服务

文件：

- `scripts/openclaw_workspace_image_server.mjs`
- `scripts/run_openclaw_workspace_image_server.sh`

用途：

- 在 OpenClaw 机器上提供本地 HTTP 上传接口
- 接收 `multipart/form-data`
- 将图片原子写入：
  - `/Users/gunner/.openclaw/workspace/image.png`

默认接口：

- `GET /health`
- `POST /upload-image`
- `POST /tasks/openclaw`
- `GET /tasks/<id>`

### 4.2 OpenClaw HTTP 调用脚本

文件：

- `scripts/test_openclaw_responses.sh`
- `scripts/test_openclaw_responses_image.sh`
- `scripts/test_openclaw_responses_async.sh`

用途：

- 调用 OpenClaw 的 `/v1/responses`
- 支持长任务
- 支持异步后台派发，避免长流程被前台阻塞

### 4.3 Gateway WS 调试脚本

文件：

- `scripts/openclaw_gateway_ws_chat.mjs`
- `scripts/test_openclaw_ws_chat.sh`

用途：

- 用于调试 Gateway Protocol / `chat.send`
- 已验证设备签名、配对与 `chat.send`
- 但最终结论是这条路线不适合作为本次稳定方案

## 5. 当前稳定使用方式

## 5.1 在 OpenClaw 机器上启动图片上传服务

```bash
WORKSPACE_IMAGE_SERVER_TOKEN='17097448ak47' \
WORKSPACE_IMAGE_PATH='/Users/gunner/.openclaw/workspace/image.png' \
bash /Volumes/Data/workspace/VP/SpatialYOLO1/scripts/run_openclaw_workspace_image_server.sh
```

## 5.2 上传图片到 workspace

```bash
curl -H "Authorization: Bearer 17097448ak47" \
  -F "file=@/path/to/your-image.jpg" \
  http://127.0.0.1:18888/upload-image
```

返回示例：

```json
{
  "saved": true,
  "path": "/Users/gunner/.openclaw/workspace/image.png",
  "bytes": 5867,
  "mimeType": "image/jpeg",
  "filename": "test.jpeg",
  "fieldName": "file"
}
```

## 5.3 同步调用 OpenClaw

```bash
OPENCLAW_TOKEN='17097448ak47' \
OPENCLAW_MAX_TIME=0 \
bash /Volumes/Data/workspace/VP/SpatialYOLO1/scripts/test_openclaw_responses.sh \
'MEDIA:/Users/gunner/.openclaw/workspace/image.png 使用 skill淘宝搜索并加入购物车'
```

说明：

- `OPENCLAW_MAX_TIME=0` 表示不设置总超时
- 长流程不会再被 `curl --max-time 120` 中断

## 5.4 异步派发长任务

```bash
OPENCLAW_TOKEN='17097448ak47' \
OPENCLAW_MAX_TIME=0 \
bash /Volumes/Data/workspace/VP/SpatialYOLO1/scripts/test_openclaw_responses_async.sh \
'MEDIA:/Users/gunner/.openclaw/workspace/image.png 使用 skill淘宝搜索并加入购物车'
```

返回示例：

```text
PID=77753
OUT=/tmp/openclaw-responses-20260309-235905-77751.out
ERR=/tmp/openclaw-responses-20260309-235905-77751.err
```

后续查看结果：

```bash
cat /tmp/openclaw-responses-20260309-235905-77751.out
cat /tmp/openclaw-responses-20260309-235905-77751.err
```

## 5.5 Vision Pro 端最终调用模式

Vision Pro App 不再实时等待 OpenClaw 长任务完成，而是：

1. 提交任务到：
   - `POST /tasks/openclaw`
2. 服务端立即返回任务 ID
3. App 每 2 秒轮询：
   - `GET /tasks/<id>`
4. UI 展示任务状态：
   - `queued`
   - `processing`
   - `completed`
   - `failed`

这样可以避免 Vision Pro 端因长时间等待而超时。

## 6. 已验证结果

一次成功返回示例如下：

- 登录状态：已登录 `gunnerak`
- 图片上传：成功
- 搜索结果：找到 10+ 个相似商品
- 加入购物车：成功

示例选中商品：

- `Breville铂富BES870家用意式半自动咖啡机`
- 价格：`¥4090`
- 店铺：`铂富酷客意德专卖店`
- 商品链接：`https://detail.tmall.com/item.htm?id=692549325410`

## 7. 适合博客写法的主线

这篇博客建议按下面结构展开：

### 7.1 问题定义

- 想做“图片 -> OpenClaw -> 淘宝 skill -> 加购”
- 难点不在淘宝自动化，而在图片输入链路

### 7.2 尝试过但不稳定的方案

- `/v1/chat/completions`
- `/v1/responses + input_image`
- Gateway WS `chat.send + attachments`
- Web UI 粘贴图片

### 7.3 关键观察

- OpenClaw 最终总是尝试读取：
  - `/Users/gunner/.openclaw/workspace/image.png`
- 所以最稳方案是自己把图片写到这个路径

### 7.4 最终方案

- 自定义上传服务写 workspace
- 再通过 OpenClaw 文本 prompt 驱动 skill

### 7.5 优点

- 不依赖 OpenClaw 当前不稳定的附件落盘实现
- 与 skill 现有读取逻辑保持一致
- 对外部客户端最容易集成

## 8. 后续可优化项

- 支持唯一文件名，避免并发上传互相覆盖
- 在上传服务里返回可直接拼接的 `MEDIA:` 路径
- 增加任务状态查询脚本，避免异步长任务只能手工 `tail`
- 将“上传 + 调用 OpenClaw”封装成一个一键脚本

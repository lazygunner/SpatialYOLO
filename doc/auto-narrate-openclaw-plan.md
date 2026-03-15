# Auto 模式灵敏度提升与 OpenClaw 集成方案

## 1. 文档目标

本文档用于整理 AI Live 中 Gemini Auto 模式的后续开发方向，覆盖三部分：

- 提升 Auto 模式对画面变化的灵敏度与触发频率
- 增加基于本地语音转写关键词的 OpenClaw 图片上传触发
- 说明 OpenClaw 部署在 UTM 虚拟机中时的局域网访问方案

本文档优先基于当前仓库现状整理，避免重复实现已经落地的逻辑。

## 1.1 最新实践更新（2026-03-10）

经过联调，OpenClaw 最稳定的图片处理链路已经从“直接把图片塞给 OpenClaw API”调整为：

1. Vision Pro 将当前相机画面压缩为 JPEG
2. 上传到 OpenClaw 所在机器上的本地图片服务
3. 该服务将图片固定写入：
   - `/Users/gunner/.openclaw/workspace/image.png`
4. 再由该服务异步提交 OpenClaw 长任务
5. Vision Pro 端定时轮询任务状态
6. prompt 使用：
   - `MEDIA:/Users/gunner/.openclaw/workspace/image.png 使用 skill淘宝搜索并加入购物车`

这条链路已经实测成功，可参考：

- `doc/openclaw-taobao-image-workflow.md`

因此，原文档中“直接调用 OpenClaw 上传媒体接口”的部分应视为早期探索，不再是最终推荐方案。

## 2. 当前实现现状

### 2.1 已经存在的逻辑

- `SpatialYOLO/AppModel+GeminiLive.swift`
  - `stopGeminiSession()` 已经会重置 `isVoiceSamplingActive = false`
  - 停止会话时也会清空 `lastSentThumbnail`
- `SpatialYOLO/AppModel.swift`
  - Auto 模式当前使用图像缩略图 MSE 做场景变化检测
  - 当前参数：
    - `narrationCooldown = 6`
    - `sceneChangeThreshold = 0.04`
  - Gemini Live 当前采样频率为 `1fps`
- `SpatialYOLO/AppModel+GeminiLive.swift`
  - Auto 模式当前仅依赖像素变化触发，不再依赖标签去重

### 2.2 已过时或无需再做的提案项

- `Reset isVoiceSamplingActive = false in stopGeminiSession`
  - 已完成，无需重复修改
- `Remove lastNarratedLabels from AppModel`
  - 当前代码中已不存在 `lastNarratedLabels`，无需处理

### 2.3 当前问题

虽然 Auto 模式已经比早期版本更简单，但现在仍然偏保守：

- 只有 `1fps` 采样，响应新场景会有体感延迟
- `6s cooldown` 偏长，明显换景后也要等待
- MSE 阈值固定，无法区分“小幅移动”和“明显换景”
- OpenClaw 触发链路尚未接入

## 3. 开发目标

### 3.1 Auto 模式

- 更快感知明显画面变化
- 在不持续“碎碎念”的前提下，提高触发频率
- 保持当前后台 JPEG 压缩和 WebSocket 发送链路不被阻塞

### 3.2 OpenClaw 联动

- 当本地转写识别到“购物车”或“Shopping Cart”时，上传最近一帧 JPEG 到 OpenClaw
- 避免同一句话连续触发多次
- URL 不硬编码到业务逻辑中，支持后续切换网关地址

## 4. 推荐方案

### 4.1 Auto 模式参数调整

建议先做一版保守增强，而不是一次性改得过于激进：

| 项目 | 当前 | 建议 |
|------|------|------|
| 视频采样频率 | 1fps | Auto 模式下提升到 2fps (`0.5s`) |
| 解说冷却时间 | 6s | 降到 3s |
| MSE 阈值 | 0.04 | 先降到 0.025 |

推荐原因：

- `0.5s` 采样能显著缩短“转头看到新物体”到“触发解说”的等待
- `3s cooldown` 依然能抑制连续播报，但不会过于迟钝
- `0.025` 对换景更灵敏，同时仍高于轻微手抖和头部微动造成的噪声

### 4.1.1 建议新增常量

建议将 Auto 相关参数从分散常量收敛成一组明确配置：

- `autoNarrateFrameInterval: TimeInterval = 0.5`
- `autoNarrateCooldown: TimeInterval = 3.0`
- `sceneChangeThreshold: Float = 0.025`

说明：

- 若后续需要调参，可进一步迁移到 `Config.plist`
- 第一版不建议暴露到 UI，先以代码常量收敛

### 4.1.2 触发门控建议

为了避免“更灵敏”直接演变成“更吵”，建议保留以下门控：

- AI 正在说话时不重复触发新的自动解说
- 必须满足最小 cooldown
- 只有 MSE 超过阈值才触发

可选增强，但不是第一版必须项：

- 当 MSE 介于 `0.025 ~ 0.04` 时，要求连续两帧都超过阈值再触发
- 当 MSE 大于 `0.06` 时直接触发，作为“明显换景”快速路径

这样可以兼顾“对大变化快响应”和“对轻微抖动不敏感”。

### 4.2 AppModel 改动建议

### 4.2.1 建议新增状态

在 `SpatialYOLO/AppModel.swift` 中新增：

- `lastProcessedFrame: Data?`
  - 保存最近一次压缩完成的 JPEG
  - 供 OpenClaw 上传复用
- `lastTriggeredTranscript: String = ""`
  - 记录最近一次已触发的关键词文本
  - 防止同一段局部转写重复触发
- `lastOpenClawTriggerTime: Date = .distantPast`
  - 建议新增，避免连续 partial transcript 抖动

说明：

- `lastProcessedFrame` 存的是“最近处理完成的一帧”，并非严格意义上的“最新原始帧”
- 这样做的优点是无需为了 OpenClaw 再单独压缩一次图像，链路更简单
- 如果后续确实要求“关键词出现瞬间抓拍”，再补一个专用抓拍方法更合适

### 4.2.2 建议新增方法

在 `AppModel` 中新增：

```swift
func checkTriggers(transcript: String)
```

职责：

- 统一做关键词检测
- 对 transcript 做归一化处理
- 去重和 cooldown 控制
- 触发 OpenClaw 上传

建议检测关键词：

- `购物车`
- `shopping cart`

建议做法：

- 统一转小写
- 去掉首尾空格
- 只要包含关键词即可命中
- 若与 `lastTriggeredTranscript` 相同且仍在短时间窗口内，则忽略

### 4.3 AudioInputMonitor 观察方式

原提案提到“通过 `didSet` 或 observer 监听 `localTranscript`”。基于当前代码结构，更推荐显式回调，而不是在 `AppModel` 里依赖嵌套属性的 `didSet`。

### 4.3.1 推荐方案

在 `SpatialYOLO/AudioInputMonitor.swift` 中新增一个轻量回调：

```swift
var onTranscriptChanged: ((String) -> Void)?
```

在本地 STT 得到 partial/final 文本时回调给 `AppModel`：

- partial transcript 更新时回调
- final transcript 清空前也可回调一次

然后在 `AppModel.startGeminiSession()` 中绑定：

```swift
audioInputMonitor.onTranscriptChanged = { [weak self] text in
    Task { @MainActor in
        self?.checkTriggers(transcript: text)
    }
}
```

这样比依赖 `didSet` 更直接，原因是：

- `localTranscript` 属于嵌套的 `@Observable` 对象
- `AppModel` 自身无法天然通过 `didSet` 感知其内部属性变化
- 回调更容易做去重、节流和后续扩展

### 4.4 OpenClawService 设计

新增文件：

- `SpatialYOLO/OpenClawService.swift`

最终建议接口：

```swift
final class OpenClawService {
    func submitShoppingCartTask(jpegData: Data) async throws
    func fetchTask(id: String) async throws
}
```

### 4.4.1 配置建议

不要将地址和 token 写死在代码中。建议新增配置项：

- `OPENCLAW_GATEWAY_BASE_URL`
- `OPENCLAW_UPLOAD_BASE_URL`
- `OPENCLAW_TOKEN`
- `OPENCLAW_UPLOAD_TOKEN`
- `OPENCLAW_WORKSPACE_IMAGE_PATH`
- `OPENCLAW_MODEL`

放入 `SpatialYOLO/Config.plist`：

```xml
<key>OPENCLAW_GATEWAY_BASE_URL</key>
<string>http://192.168.2.142:18789</string>
<key>OPENCLAW_UPLOAD_BASE_URL</key>
<string>http://192.168.2.142:18888</string>
<key>OPENCLAW_TOKEN</key>
<string>YOUR_TOKEN_HERE</string>
<key>OPENCLAW_UPLOAD_TOKEN</key>
<string>YOUR_TOKEN_HERE</string>
<key>OPENCLAW_MODEL</key>
<string>openclaw:main</string>
<key>OPENCLAW_WORKSPACE_IMAGE_PATH</key>
<string>/Users/gunner/.openclaw/workspace/image.png</string>
```

并同步更新：

- `SpatialYOLO/Config.plist.example`

### 4.4.2 上传协议

最终建议目标接口：

- 图片上传服务：
  - `POST http://<openclaw-host>:18888/upload-image`
- 异步任务服务：
  - `POST http://<openclaw-host>:18888/tasks/openclaw`
  - `GET http://<openclaw-host>:18888/tasks/<id>`
- OpenClaw Gateway：
  - `POST http://<openclaw-host>:18789/v1/responses`

请求格式：

- 上传服务使用 `multipart/form-data`
- 文件字段名使用 `file`
- MIME 类型使用 `image/jpeg`
- OpenClaw prompt 使用：
  - `MEDIA:/Users/gunner/.openclaw/workspace/image.png 使用 skill淘宝搜索并加入购物车`
- Vision Pro 端只提交任务，不同步等待任务完成

### 4.5 Gemini 帧处理链路改造点

在 `SpatialYOLO/AppModel+GeminiLive.swift` 的 JPEG 压缩成功后，在主线程同步保存：

- `lastProcessedFrame = jpegData`

顺序建议如下：

1. 生成 JPEG
2. 保存 `lastProcessedFrame`
3. 发送给当前 AI Service
4. 保存录制帧
5. 执行 Auto 模式 MSE 判定

这样可以保证：

- OpenClaw 使用的是同一条压缩链路产出的图片
- 关键词触发或手动按钮都能拿到最近一帧

## 5. 建议实现顺序

### 阶段 1：先做 Auto 模式增强

修改文件：

- `SpatialYOLO/AppModel.swift`
- `SpatialYOLO/AppModel+GeminiLive.swift`

目标：

- Auto 模式采样从 `1fps` 提升到 `2fps`
- cooldown 从 `6s` 降到 `3s`
- MSE 阈值从 `0.04` 降到 `0.025`

### 阶段 2：接入 OpenClaw 基础上传

新增文件：

- `SpatialYOLO/OpenClawService.swift`

修改文件：

- `SpatialYOLO/AppModel.swift`
- `SpatialYOLO/AppModel+GeminiLive.swift`
- `SpatialYOLO/AudioInputMonitor.swift`
- `SpatialYOLO/Config.plist.example`

目标：

- 存储最近 JPEG
- 监听本地 transcript
- 命中关键词后调用“上传 workspace 图片 + `/v1/responses` prompt”

### 阶段 3：补体验反馈

可选：

- 本地 toast / HUD 提示“已发送到 OpenClaw”
- 轻量音效或 haptic
- 上传失败时输出更明确日志

## 6. 手工验证方案

### 6.1 Auto 模式

1. 启动 AI Live 并启用 `AUTO`
2. 对准稳定场景，确认不会频繁播报
3. 快速转向新场景，例如从桌面转到门口或人物
4. 观察是否在约 `0.5s ~ 3s` 内更快触发
5. 连续小幅晃动头部，确认不会持续 chatter

重点观察：

- 是否比当前版本更快开始描述新场景
- 是否在 AI 自己讲话时又重复打断
- 是否因轻微运动导致过度触发

### 6.2 OpenClaw 关键词触发

1. 启动会话，确保本地 STT 正常工作
2. 等待 `lastProcessedFrame` 已有值
3. 说出“购物车”或 “Shopping Cart”
4. 检查是否只触发一次上传
5. 短时间内重复相同词组，确认不会连续上传

重点观察：

- partial transcript 是否造成重复触发
- 当前画面 JPEG 是否成功送到网关
- 上传失败时日志是否能定位问题

## 7. UTM 虚拟机中的 OpenClaw 局域网访问

### 7.1 先确认问题本质

如果 OpenClaw 运行在 UTM 虚拟机里，Vision Pro 应用无法访问 `http://192.168.1.188:18789`，通常不是 App 代码问题，而是以下几类网络问题之一：

- UTM 网络模式不适合从局域网直接访问
- OpenClaw 服务只监听了 `127.0.0.1`
- 虚拟机防火墙未放行 `18789`
- 你使用的是宿主机 IP，但端口实际没有转发到虚拟机

### 7.1.1 服务监听地址

先确保 OpenClaw 在虚拟机里监听的是：

- `0.0.0.0:18789`

而不是：

- `127.0.0.1:18789`

如果只监听 `127.0.0.1`，宿主机和其他局域网设备都无法访问。

### 7.2 推荐方案 A：UTM 使用 Bridged 网络

这是最适合“让 Vision Pro 直接访问虚拟机服务”的方案。

做法：

1. 将 UTM 虚拟机网卡改为 `Bridged`
2. 桥接到宿主机正在使用的物理网卡
3. 让虚拟机从路由器获取一个独立局域网 IP
4. 将 `OPENCLAW_GATEWAY_BASE_URL` 配置为虚拟机自己的 IP，例如：
   - `http://<vm-lan-ip>:18789`

适用场景：

- Vision Pro 需要直接访问虚拟机里的服务
- 不希望依赖宿主机做额外代理

注意事项：

- UTM 官方文档说明 `Bridged` 属于高级模式
- 若桥接的是 Wi-Fi，可能需要额外配置，且兼容性不如有线网卡稳定

参考：

- [UTM Network 模式说明](https://docs.getutm.app/settings-apple/devices/network/)

### 7.3 方案 B：让宿主机作为入口，再转发到虚拟机

如果桥接网络不好配，或者当前 VM 不是直接暴露在局域网中，可以让 Mac 宿主机对外暴露一个端口，再把流量转给虚拟机中的 OpenClaw。

然后 Vision Pro 配置访问：

- `http://<mac-lan-ip>:18789`

### 7.3.1 QEMU + Emulated VLAN

如果你的 UTM VM 使用的是 QEMU backend 且网络模式为 `Emulated VLAN`，可以直接使用 UTM 的端口转发。

UTM 官方说明：

- 端口转发只适用于 `QEMU backend + Emulated VLAN`

参考：

- [UTM Port Forwarding 文档](https://docs.getutm.app/settings-qemu/devices/network/port-forwarding/)

做法：

1. 在 UTM 中新增一条 TCP 转发
2. `Host Port = 18789`
3. `Guest Port = 18789`
4. `Host Address` 如果留空，通常只监听本机回环

如果希望让 Vision Pro 也能访问，通常还需要让宿主机在局域网地址上监听，或额外加一层宿主机代理。

### 7.3.2 宿主机代理

如果你的网络模式不支持直接转发到局域网，可在宿主机上做一层反向代理或 TCP 转发：

- `nginx`
- `caddy`
- `socat`

思路是：

- 宿主机监听 `0.0.0.0:18789`
- 再把请求转发到虚拟机里的 `18789`

这样 Vision Pro 只访问 Mac 的局域网 IP 即可。

### 7.4 方案选择建议

如果你的目标是“Vision Pro 直接访问 OpenClaw”：

- 首选 `Bridged`，让 VM 获得独立局域网 IP

如果你的目标是“先尽快打通，不折腾 UTM 桥接”：

- 用“宿主机代理到 VM”通常更容易

### 7.5 排查清单

先在虚拟机内确认：

- OpenClaw 监听 `0.0.0.0:18789`
- 虚拟机内防火墙已放行 `18789`
- 虚拟机内执行 `curl http://127.0.0.1:18789/...` 正常

再在宿主机确认：

- 能否访问虚拟机 IP 的 `18789`
- 如果不能，先看 UTM 网络模式

最后在 Vision Pro 所在网络确认：

- Vision Pro 与宿主机或 VM 是否在同一网段
- 是否存在企业 Wi-Fi、AP 隔离、访客网络等限制

## 8. 实施备注

### 8.1 配置项建议

后续建议新增以下配置项：

- `OPENCLAW_GATEWAY_BASE_URL`
- `OPENCLAW_TRIGGER_KEYWORDS`

第一版也可以只先支持固定关键词：

- `购物车`
- `Shopping Cart`

### 8.2 日志建议

建议增加统一日志前缀：

- `[AutoNarrate]`
- `[OpenClaw]`
- `[Trigger]`

这样设备调试时更容易筛选链路问题。

## 9. 结论

这次需求中，真正需要开发的核心点有两个：

- Auto 模式从“1fps + 6s + 0.04”调整为更灵敏的触发参数
- 新增 OpenClaw 关键词上传链路

而 `stopGeminiSession()` 重置 `isVoiceSamplingActive` 与 `lastNarratedLabels` 清理这两项，当前仓库里已经不再是待办。

//
//  MahjongAnalysisService.swift
//  SpatialYOLO
//
//  Created by Claude on 2026/2/19.
//

import Foundation

/// 麻将牌型分析服务
/// 使用 DashScope OpenAI 兼容 API 调用 qwen-plus 模型进行独立牌型分析
@Observable
class MahjongAnalysisService {

    // MARK: - 公开状态

    var analysisResult: String = ""   // 最新分析结果
    var isAnalyzing: Bool = false     // 是否正在分析中

    // MARK: - Private

    private let apiKey: String
    private let endpoint = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
    private let model = "qwen3.5-397b-a17b"

    /// 多轮对话历史（system + user/assistant 交替）
    private var messages: [[String: String]] = []

    /// 专用 URLSession：避免 shared session 的默认超时限制
    private let urlSession: URLSession

    private let systemPrompt = """
    你是杭州麻将分析助手。收到手牌后，只输出以下两部分，不要废话：

    【牌型】列出当前已有的面子（顺/刻）、对子、搭子，并给出最优打牌建议（一句话）。
    【胡牌路线】列出1-3条最有希望的听牌/胡牌方案，每条注明还差几张、需要什么牌，以及大致概率（高/中/低）。

    格式简洁，总字数控制在150字以内。
    """

    // MARK: - Init

    init(apiKey: String) {
        self.apiKey = apiKey
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120   // 等待服务器第一字节的超时
        config.timeoutIntervalForResource = 300  // 整个请求完成的超时
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - 公开方法

    /// 分析手牌，结合打牌记录
    /// - Parameters:
    ///   - handTiles: 手牌编码数组（如 ["1C", "2C", "3C"]）
    ///   - tileNames: 牌编码到中文名映射
    ///   - tileEmojis: 牌编码到 emoji 映射
    ///   - discardRecords: 各玩家打牌记录
    func analyze(
        handTiles: [String],
        tileNames: [String: String],
        tileEmojis: [String: String],
        discardRecords: [PlayerDiscardRecord]
    ) async {
        guard !apiKey.isEmpty else {
            print("[MahjongAnalysis] API Key 为空，无法分析")
            await MainActor.run { analysisResult = "错误：未配置 API Key" }
            return
        }
        guard !handTiles.isEmpty else {
            print("[MahjongAnalysis] 手牌为空，无法分析")
            return
        }

        await MainActor.run {
            isAnalyzing = true
            analysisResult = "分析中..."
        }

        // 构建用户消息
        let userMessage = buildUserMessage(
            handTiles: handTiles,
            tileNames: tileNames,
            tileEmojis: tileEmojis,
            discardRecords: discardRecords
        )

        print("[MahjongAnalysis] 发送分析请求，手牌 \(handTiles.count) 张，打牌记录 \(discardRecords.count) 位玩家")

        // 首次调用时添加 system prompt
        if messages.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        messages.append(["role": "user", "content": userMessage])

        // 限制对话历史：保留 system prompt + 最近 10 条（5 轮）
        trimHistory()

        // 调用 SSE 流式 API
        do {
            let result = try await callAPI()
            messages.append(["role": "assistant", "content": result])
            print("[MahjongAnalysis] 流式分析完成，结果长度: \(result.count)")
            await MainActor.run { isAnalyzing = false }
        } catch {
            print("[MahjongAnalysis] 分析失败: \(error)")
            await MainActor.run {
                analysisResult = "分析失败: \(error.localizedDescription)"
                isAnalyzing = false
            }
        }
    }

    /// 重置对话历史（新牌局时调用）
    func resetConversation() {
        messages = []
        analysisResult = ""
        print("[MahjongAnalysis] 对话历史已重置")
    }

    // MARK: - Private

    /// 保留 system prompt + 最近 10 条消息（5 轮对话）
    private func trimHistory() {
        let maxUserAssistantMessages = 10
        let systemMessages = messages.filter { $0["role"] == "system" }
        var otherMessages = messages.filter { $0["role"] != "system" }
        if otherMessages.count > maxUserAssistantMessages {
            otherMessages = Array(otherMessages.suffix(maxUserAssistantMessages))
        }
        messages = systemMessages + otherMessages
    }

    /// 构建用户消息
    private func buildUserMessage(
        handTiles: [String],
        tileNames: [String: String],
        tileEmojis: [String: String],
        discardRecords: [PlayerDiscardRecord]
    ) -> String {
        // 按花色分组
        var wan: [String] = []
        var tiao: [String] = []
        var tong: [String] = []
        var feng: [String] = []
        var jian: [String] = []
        var hua: [String] = []

        let dragonCodes: Set = ["RD", "GD", "WD"]
        let windCodes: Set = ["EW", "SW", "WW", "NW"]

        for code in handTiles {
            let name = tileNames[code] ?? code
            let emoji = tileEmojis[code] ?? ""
            let display = "\(emoji)\(name)"

            if dragonCodes.contains(code) { jian.append(display) }
            else if windCodes.contains(code) { feng.append(display) }
            else if code.hasSuffix("C") { wan.append(display) }
            else if code.hasSuffix("B") { tiao.append(display) }
            else if code.hasSuffix("D") { tong.append(display) }
            else if code.hasSuffix("F") || code.hasSuffix("S") { hua.append(display) }
        }

        var prompt = "我当前的麻将手牌如下：\n"
        if !wan.isEmpty  { prompt += "万子：\(wan.joined(separator: " "))\n" }
        if !tiao.isEmpty { prompt += "条子：\(tiao.joined(separator: " "))\n" }
        if !tong.isEmpty { prompt += "筒子：\(tong.joined(separator: " "))\n" }
        if !feng.isEmpty { prompt += "风牌：\(feng.joined(separator: " "))\n" }
        if !jian.isEmpty { prompt += "箭牌：\(jian.joined(separator: " "))\n" }
        if !hua.isEmpty  { prompt += "花牌：\(hua.joined(separator: " "))\n" }
        prompt += "共 \(handTiles.count) 张牌。\n"

        // 添加打牌记录
        if !discardRecords.isEmpty {
            prompt += "\n其他玩家的出牌记录：\n"
            for record in discardRecords {
                if !record.events.isEmpty {
                    let eventStrs = record.events.map { event in
                        "\(event.action) \(event.tile)"
                    }
                    prompt += "\(record.player)：\(eventStrs.joined(separator: "、"))\n"
                }
            }
        }

        prompt += "\n请分析。"
        return prompt
    }

    /// 调用 DashScope API（SSE 流式，避免非流式等待整个响应导致超时）
    /// timeoutIntervalForRequest 是两个数据包之间的间隔超时，流式模式下每个 token 都会重置计时
    private func callAPI() async throws -> String {
        let url = URL(string: endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.3,
            "max_tokens": 400,
            "stream": true,
            "enable_thinking": false   // 禁用 Qwen3 思考模式，直接输出结果更快
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // bytes(for:) 返回 AsyncBytes，逐行读取 SSE 事件
        let (bytes, response) = try await urlSession.bytes(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            print("[MahjongAnalysis] HTTP 状态码: \(httpResponse.statusCode)")
            if httpResponse.statusCode != 200 {
                var errorBody = ""
                for try await line in bytes.lines {
                    errorBody += line + "\n"
                    if errorBody.count > 500 { break }
                }
                print("[MahjongAnalysis] 错误响应: \(errorBody.prefix(500))")
                throw NSError(domain: "MahjongAnalysis", code: httpResponse.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(String(errorBody.prefix(200)))"])
            }
        }

        // 解析 SSE 流（data: {...} 逐行）
        // Qwen3 默认开启思考模式：前半段 delta 只有 reasoning_content（content 为空），
        // 后半段 delta 的 content 才是真正的回答。
        var fullContent = ""
        var isThinking = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let dataStr = String(line.dropFirst(6))
            if dataStr.trimmingCharacters(in: .whitespaces) == "[DONE]" { break }

            guard let data = dataStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else {
                continue
            }

            // 思考阶段：有 reasoning_content 但 content 为空
            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                if !isThinking {
                    isThinking = true
                    await MainActor.run { analysisResult = "思考中..." }
                }
                continue
            }

            // 回答阶段：提取 content，空字符串跳过（不覆盖已有内容）
            guard let token = delta["content"] as? String, !token.isEmpty else { continue }

            if isThinking {
                isThinking = false  // 思考结束，开始输出正文
            }
            fullContent += token
            // 实时更新 UI（打字机效果）
            let snapshot = fullContent
            await MainActor.run {
                analysisResult = snapshot
            }
        }

        if fullContent.isEmpty {
            throw NSError(domain: "MahjongAnalysis", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "响应内容为空"])
        }
        return fullContent
    }
}

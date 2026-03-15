//
//  OpenClawService.swift
//  SpatialYOLO
//
//  OpenClaw 图片上传 + Prompt 调用服务
//

import Foundation

struct OpenClawService {

    enum TaskStatus: String, Codable {
        case queued
        case processing
        case completed
        case failed

        var isTerminal: Bool {
            self == .completed || self == .failed
        }
    }

    struct Configuration {
        let gatewayBaseURL: URL?
        let uploadBaseURL: URL?
        let gatewayToken: String
        let uploadToken: String
        let model: String
        let workspaceImagePath: String

        var isConfigured: Bool {
            uploadBaseURL != nil &&
            !uploadToken.isEmpty &&
            !workspaceImagePath.isEmpty
        }
    }

    struct UploadResponse: Decodable {
        let saved: Bool?
        let path: String?
        let bytes: Int?
        let mimeType: String?
        let filename: String?
        let fieldName: String?
    }

    struct RunResult {
        let upload: UploadResponse
        let prompt: String
        let responseText: String
    }

    struct TaskResponse: Decodable {
        let id: String
        let executor: String?
        let status: TaskStatus
        let prompt: String
        let stepKey: String?
        let stepLabel: String?
        let stepIndex: Int?
        let totalSteps: Int?
        let progress: Double?
        let stepUpdatedAt: String?
        let sourceImagePath: String?
        let sourceMimeType: String?
        let workspaceImagePath: String?
        let createdAt: String?
        let updatedAt: String?
        let responseText: String?
        let error: String?
        let artifactsDir: String?
    }

    private struct ResponsesEnvelope: Decodable {
        struct OutputItem: Decodable {
            struct ContentItem: Decodable {
                let type: String?
                let text: String?
            }

            let type: String?
            let role: String?
            let content: [ContentItem]?
        }

        let output: [OutputItem]?
    }

    let configuration: Configuration
    private let session: URLSession

    init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func makeShoppingCartPrompt() -> String {
        "MEDIA:\(configuration.workspaceImagePath) 使用 skill淘宝搜索并加入购物车"
    }

    func submitShoppingCartTask(jpegData: Data, prompt: String? = nil) async throws -> TaskResponse {
        guard let uploadBaseURL = configuration.uploadBaseURL else {
            throw OpenClawError.misconfigured("未配置 OpenClaw 上传服务地址")
        }

        let finalPrompt = prompt ?? makeShoppingCartPrompt()
        let boundary = "Boundary-\(UUID().uuidString)"
        let endpoint = uploadBaseURL
            .appendingPathComponent("tasks")
            .appendingPathComponent("openclaw")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(configuration.uploadToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"image.jpg\"\r\n")
        body.appendString("Content-Type: image/jpeg\r\n\r\n")
        body.append(jpegData)
        body.appendString("\r\n")
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
        body.appendString(finalPrompt)
        body.appendString("\r\n--\(boundary)--\r\n")

        let (data, response) = try await session.upload(for: request, from: body)
        do {
            try validate(response: response, data: data)
        } catch OpenClawError.httpError(let statusCode, _) where statusCode == 404 {
            throw OpenClawError.invalidResponse("任务接口不存在，请重启 OpenClaw 机器上的图片服务以加载 /tasks/openclaw")
        }
        return try JSONDecoder().decode(TaskResponse.self, from: data)
    }

    func fetchTask(id: String) async throws -> TaskResponse {
        guard let uploadBaseURL = configuration.uploadBaseURL else {
            throw OpenClawError.misconfigured("未配置 OpenClaw 上传服务地址")
        }

        let endpoint = uploadBaseURL
            .appendingPathComponent("tasks")
            .appendingPathComponent(id)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(configuration.uploadToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(TaskResponse.self, from: data)
    }

    func uploadWorkspaceImage(jpegData: Data) async throws -> UploadResponse {
        guard let uploadBaseURL = configuration.uploadBaseURL else {
            throw OpenClawError.misconfigured("未配置 OpenClaw 上传服务地址")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        let endpoint = uploadBaseURL.appendingPathComponent("upload-image")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(configuration.uploadToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"image.jpg\"\r\n")
        body.appendString("Content-Type: image/jpeg\r\n\r\n")
        body.append(jpegData)
        body.appendString("\r\n--\(boundary)--\r\n")

        let (data, response) = try await session.upload(for: request, from: body)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(UploadResponse.self, from: data)
    }

    func sendPrompt(_ prompt: String) async throws -> String {
        guard let gatewayBaseURL = configuration.gatewayBaseURL else {
            throw OpenClawError.misconfigured("未配置 OpenClaw Gateway 地址")
        }

        let endpoint = gatewayBaseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("responses")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue("Bearer \(configuration.gatewayToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": configuration.model,
            "input": prompt
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        let envelope = try JSONDecoder().decode(ResponsesEnvelope.self, from: data)
        let text = envelope.output?
            .flatMap { $0.content ?? [] }
            .compactMap { $0.text }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if text.isEmpty {
            throw OpenClawError.invalidResponse("OpenClaw 返回成功，但没有可读文本")
        }

        return text
    }

    func runShoppingCartFlow(jpegData: Data, prompt: String? = nil) async throws -> RunResult {
        let upload = try await uploadWorkspaceImage(jpegData: jpegData)
        let finalPrompt = prompt ?? makeShoppingCartPrompt()
        let responseText = try await sendPrompt(finalPrompt)
        return RunResult(upload: upload, prompt: finalPrompt, responseText: responseText)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenClawError.invalidResponse("OpenClaw 返回了非 HTTP 响应")
        }

        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw OpenClawError.httpError(statusCode: http.statusCode, body: text)
        }
    }
}

enum OpenClawError: LocalizedError {
    case misconfigured(String)
    case invalidResponse(String)
    case httpError(statusCode: Int, body: String?)

    var errorDescription: String? {
        switch self {
        case .misconfigured(let message):
            return message
        case .invalidResponse(let message):
            return message
        case .httpError(let statusCode, let body):
            if let body, !body.isEmpty {
                return "OpenClaw HTTP \(statusCode): \(body)"
            }
            return "OpenClaw HTTP \(statusCode)"
        }
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}

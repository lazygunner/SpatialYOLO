//
//  CloudMemorySyncService.swift
//  SpatialYOLO
//
//  将本地回忆会话同步到 Cloud Run + Cloud Storage + 数据库
//

import Foundation

enum CloudSyncState: String, Codable {
    case notConfigured
    case pending
    case syncing
    case synced
    case failed

    var needsUpload: Bool {
        switch self {
        case .pending, .syncing, .failed:
            return true
        case .notConfigured, .synced:
            return false
        }
    }
}

struct CloudMemorySyncConfiguration {
    let baseURL: URL?
    let token: String

    var isConfigured: Bool { baseURL != nil }

    static func current() -> CloudMemorySyncConfiguration {
        let base = AppModel.loadMemorySyncBaseURL()
        return CloudMemorySyncConfiguration(
            baseURL: URL(string: base),
            token: AppModel.loadMemorySyncToken()
        )
    }
}

private struct CloudMemoryFramePayload: Codable {
    let name: String
    let imageFileName: String
    let context: String
    let aiResponse: String
}

private struct CloudMemorySessionPayload: Codable {
    let id: String
    let startedAt: String
    let endedAt: String?
    let locationName: String
    let frameCount: Int
    let sizeBytes: Int64
    let status: String
    let thumbnailFileName: String?
    let coverFileName: String?
    let frames: [CloudMemoryFramePayload]
    let appVersion: String
    let buildNumber: String
    let deviceModel: String
}

private struct CloudMemoryUploadPayload: Codable {
    let userId: String
    let session: CloudMemorySessionPayload
}

private struct CloudMemoryUploadResponse: Decodable {
    let sessionId: String
    let recordPath: String?
    let syncedAt: String?
}

private struct CloudMemoryUploadBundle {
    let payload: CloudMemoryUploadPayload
    let fileURLs: [URL]
    let directory: URL
    let existingState: CloudSyncState
}

actor CloudMemorySyncService {
    static let shared = CloudMemorySyncService()

    private let configuration: CloudMemorySyncConfiguration
    private let session: URLSession
    private var inFlightSessionIDs: Set<String> = []

    init(
        configuration: CloudMemorySyncConfiguration = .current(),
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    func syncCompletedSessionsIfNeeded() async {
        guard configuration.isConfigured else { return }

        let sessions = SessionRecorder.listSessions()
        for sessionInfo in sessions where sessionInfo.status == .completed && sessionInfo.cloudSyncState.needsUpload {
            await syncSession(directory: sessionInfo.directory, force: sessionInfo.cloudSyncState == .failed)
        }
    }

    func syncSession(directory: URL, force: Bool = false) async {
        guard configuration.isConfigured else { return }
        guard let bundle = Self.makeUploadBundle(from: directory) else { return }

        let sessionID = bundle.payload.session.id
        if !force && bundle.existingState == .synced {
            return
        }

        guard inFlightSessionIDs.insert(sessionID).inserted else { return }
        defer { inFlightSessionIDs.remove(sessionID) }

        Self.updateCloudSyncMetadata(
            in: directory,
            state: .syncing,
            errorMessage: nil,
            recordPath: nil,
            syncedAt: nil
        )

        do {
            let response = try await upload(bundle)
            Self.updateCloudSyncMetadata(
                in: directory,
                state: .synced,
                errorMessage: nil,
                recordPath: response.recordPath,
                syncedAt: response.syncedAt
            )
            print("[CloudSync] 会话 \(sessionID) 已同步到云端")
        } catch {
            Self.updateCloudSyncMetadata(
                in: directory,
                state: .failed,
                errorMessage: Self.compactErrorMessage(error),
                recordPath: nil,
                syncedAt: nil
            )
            print("[CloudSync] 会话 \(sessionID) 同步失败: \(error.localizedDescription)")
        }
    }

    private func upload(_ bundle: CloudMemoryUploadBundle) async throws -> CloudMemoryUploadResponse {
        guard let baseURL = configuration.baseURL else {
            throw CloudMemorySyncError.misconfigured("未配置云同步服务地址")
        }

        let endpoint = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
            .appendingPathComponent("memories")

        let metadataData = try JSONEncoder().encode(bundle.payload)
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !configuration.token.isEmpty {
            request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"metadata\"\r\n")
        body.appendString("Content-Type: application/json\r\n\r\n")
        body.append(metadataData)
        body.appendString("\r\n")

        for fileURL in bundle.fileURLs {
            let filename = fileURL.lastPathComponent
            let mimeType = Self.mimeType(for: fileURL)
            let data = try Data(contentsOf: fileURL)

            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"files\"; filename=\"\(filename)\"\r\n")
            body.appendString("Content-Type: \(mimeType)\r\n\r\n")
            body.append(data)
            body.appendString("\r\n")
        }

        body.appendString("--\(boundary)--\r\n")

        let (data, response) = try await session.upload(for: request, from: body)
        try Self.validate(response: response, data: data)

        return try JSONDecoder().decode(CloudMemoryUploadResponse.self, from: data)
    }

    private static func makeUploadBundle(from directory: URL) -> CloudMemoryUploadBundle? {
        let metaURL = directory.appendingPathComponent("session.json")
        guard var meta = loadJSON(from: metaURL),
              let sessionID = meta["id"] as? String,
              let startedAt = meta["startTime"] as? String else {
            return nil
        }

        let storedUserID = (meta["userId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let userID = storedUserID.isEmpty ? LocalUserIdentity.currentUserID() : storedUserID
        meta["userId"] = userID
        saveJSON(meta, to: metaURL)

        let frameURLs = listFrameImageURLs(in: directory)
        let frames = frameURLs.map { frameURL -> CloudMemoryFramePayload in
            let baseName = frameURL.deletingPathExtension().lastPathComponent
            let contextURL = directory.appendingPathComponent("\(baseName).txt")
            let aiURL = directory.appendingPathComponent("\(baseName).ai.txt")
            let context = (try? String(contentsOf: contextURL, encoding: .utf8)) ?? ""
            let aiResponse = (try? String(contentsOf: aiURL, encoding: .utf8)) ?? ""

            return CloudMemoryFramePayload(
                name: baseName,
                imageFileName: frameURL.lastPathComponent,
                context: context,
                aiResponse: aiResponse
            )
        }

        let coverURL = directory.appendingPathComponent("cartoon.jpg")
        let hasCover = FileManager.default.fileExists(atPath: coverURL.path)
        let fileURLs = hasCover ? frameURLs + [coverURL] : frameURLs

        let sessionPayload = CloudMemorySessionPayload(
            id: sessionID,
            startedAt: startedAt,
            endedAt: meta["endTime"] as? String,
            locationName: meta["locationName"] as? String ?? "未知地点",
            frameCount: meta["frameCount"] as? Int ?? frames.count,
            sizeBytes: directorySize(at: directory),
            status: meta["status"] as? String ?? SessionStatus.completed.rawValue,
            thumbnailFileName: frameURLs.first?.lastPathComponent,
            coverFileName: hasCover ? coverURL.lastPathComponent : nil,
            frames: frames,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1",
            deviceModel: "Apple Vision Pro"
        )

        let payload = CloudMemoryUploadPayload(userId: userID, session: sessionPayload)
        let existingState = CloudSyncState(rawValue: meta["cloudSyncState"] as? String ?? "") ?? .pending

        return CloudMemoryUploadBundle(
            payload: payload,
            fileURLs: fileURLs,
            directory: directory,
            existingState: existingState
        )
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudMemorySyncError.invalidResponse("云同步服务返回了非 HTTP 响应")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CloudMemorySyncError.httpError(statusCode: httpResponse.statusCode, body: body)
        }
    }

    private static func updateCloudSyncMetadata(
        in directory: URL,
        state: CloudSyncState,
        errorMessage: String?,
        recordPath: String?,
        syncedAt: String?
    ) {
        let metaURL = directory.appendingPathComponent("session.json")
        var meta = loadJSON(from: metaURL) ?? [:]
        meta["cloudSyncState"] = state.rawValue
        meta["cloudError"] = errorMessage ?? ""
        meta["cloudRecordPath"] = recordPath ?? ""
        meta["cloudSyncedAt"] = syncedAt ?? ""
        if meta["userId"] == nil {
            meta["userId"] = LocalUserIdentity.currentUserID()
        }
        saveJSON(meta, to: metaURL)

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .refreshProjectList, object: nil)
        }
    }

    private static func compactErrorMessage(_ error: Error) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if message.count <= 240 {
            return message
        }
        return String(message.prefix(237)) + "..."
    }

    private static func listFrameImageURLs(in directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        return contents
            .filter {
                $0.pathExtension.lowercased() == "jpg" &&
                $0.deletingPathExtension().lastPathComponent.hasPrefix("frame_")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private static func loadJSON(from url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func saveJSON(_ dictionary: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary, options: .prettyPrinted) else {
            return
        }
        try? data.write(to: url)
    }

    private static func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        default:
            return "application/octet-stream"
        }
    }
}

enum CloudMemorySyncError: LocalizedError {
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
                return "Cloud sync HTTP \(statusCode): \(body)"
            }
            return "Cloud sync HTTP \(statusCode)"
        }
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}

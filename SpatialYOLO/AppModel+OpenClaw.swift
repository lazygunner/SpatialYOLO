//
//  AppModel+OpenClaw.swift
//  SpatialYOLO
//
//  OpenClaw 图片上传 + Prompt 触发逻辑
//

import Foundation
import UIKit

extension AppModel {

    private var openClawKeywords: [String] {
        [
            "加入购物车",
            "购物车",
            "加购",
            "add to cart",
            "add this to cart",
            "add this to my cart",
            "add it to cart",
            "add it to my cart",
            "put this in my cart",
            "put it in my cart",
            "put in cart",
            "put into cart",
            "shopping cart",
            "shopping basket"
        ]
    }

    var canTriggerOpenClaw: Bool {
        openClawService.configuration.isConfigured && !isOpenClawBusy
    }

    func bindOpenClawTranscriptMonitoring() {
        let handler: (String) -> Void = { [weak self] latestLine in
            Task { @MainActor in
                guard let self else { return }

                let observed = latestLine
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()

                guard observed != self.lastObservedOpenClawTranscript else { return }
                self.lastObservedOpenClawTranscript = observed
                guard !observed.isEmpty else { return }

                self.checkOpenClawTriggers(latestLine: observed)
            }
        }
        audioInputMonitor.onTranscriptPreviewChanged = handler
        audioInputMonitor.onTranscriptChanged = handler
    }

    func unbindOpenClawTranscriptMonitoring() {
        audioInputMonitor.onTranscriptPreviewChanged = nil
        audioInputMonitor.onTranscriptChanged = nil
    }

    func checkOpenClawTriggers(latestLine: String) {
        guard activeFeature == .geminiLive else { return }

        let normalized = latestLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\p{Han}]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        guard !normalized.isEmpty else { return }
        print("[OpenClaw] transcript observed: \(normalized)")
        guard let matchedKeyword = openClawKeywords.first(where: { normalized.contains($0.lowercased()) }) else {
            return
        }

        let now = Date()
        if matchedKeyword == lastTriggeredTranscript,
           now.timeIntervalSince(lastOpenClawTriggerTime) < openClawTriggerCooldown {
            print("[OpenClaw] keyword matched but skipped by cooldown: \(matchedKeyword)")
            return
        }

        lastTriggeredTranscript = matchedKeyword
        lastOpenClawTriggerTime = now
        print("[OpenClaw] trigger keyword matched: \(matchedKeyword)")
        triggerOpenClawShoppingCartFlow(source: "transcript:\(matchedKeyword)")
    }

    func triggerOpenClawShoppingCartFlow(source: String = "manual") {
        guard openClawService.configuration.isConfigured else {
            print("[OpenClaw] flow skipped: service not configured")
            openClawStatusMessage = "OpenClaw 未配置"
            return
        }

        guard !isOpenClawBusy else {
            print("[OpenClaw] flow skipped: already busy (source=\(source))")
            openClawStatusMessage = "OpenClaw 正在处理中"
            return
        }

        guard let imageData = currentOpenClawJPEGData() else {
            print("[OpenClaw] flow skipped: no jpeg available (source=\(source))")
            openClawStatusMessage = "当前没有可上传的相机画面"
            return
        }

        isOpenClawBusy = true
        openClawLastTriggerSource = source
        openClawStatusMessage = "正在提交 OpenClaw 任务..."
        print("[OpenClaw] flow started (source=\(source), bytes=\(imageData.count))")

        let service = openClawService
        Task {
            do {
                let task = try await service.submitShoppingCartTask(jpegData: imageData)
                await MainActor.run {
                    print("[OpenClaw] task submitted: id=\(task.id), status=\(task.status.rawValue)")
                    let now = Date()
                    let item = OpenClawTaskItem(
                        id: task.id,
                        status: task.status,
                        executor: task.executor ?? "unknown",
                        prompt: task.prompt,
                        stepKey: task.stepKey ?? "",
                        stepLabel: task.stepLabel ?? "",
                        stepIndex: task.stepIndex ?? 0,
                        totalSteps: task.totalSteps ?? 0,
                        progress: task.progress ?? 0,
                        createdAt: parseTaskDate(task.createdAt) ?? now,
                        updatedAt: parseTaskDate(task.updatedAt) ?? now,
                        responseText: task.responseText ?? "",
                        errorText: task.error ?? "",
                        previewJPEGData: imageData
                    )
                    upsertOpenClawTask(item)
                    openClawStatusMessage = "OpenClaw 任务已提交"
                    startPollingOpenClawTask(id: task.id)
                }
            } catch {
                await MainActor.run {
                    print("[OpenClaw] flow failed: \(error.localizedDescription)")
                    isOpenClawBusy = false
                    openClawStatusMessage = "OpenClaw 失败: \(error.localizedDescription)"
                    openClawLastResponse = ""
                }
            }
        }
    }

    private func startPollingOpenClawTask(id: String) {
        openClawPollingTasks[id]?.cancel()
        let service = openClawService

        openClawPollingTasks[id] = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                do {
                    let remoteTask = try await service.fetchTask(id: id)
                    await MainActor.run {
                        self.applyRemoteOpenClawTask(remoteTask)
                    }

                    if remoteTask.status.isTerminal {
                        await MainActor.run {
                            self.openClawPollingTasks[id] = nil
                            self.isOpenClawBusy = false
                        }
                        return
                    }
                } catch {
                    await MainActor.run {
                        print("[OpenClaw] polling failed: \(error.localizedDescription)")
                        self.openClawStatusMessage = "OpenClaw 查询失败: \(error.localizedDescription)"
                        self.isOpenClawBusy = false
                        self.openClawPollingTasks[id] = nil
                    }
                    return
                }

                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func applyRemoteOpenClawTask(_ remoteTask: OpenClawService.TaskResponse) {
        print("[OpenClaw] task update: id=\(remoteTask.id), status=\(remoteTask.status.rawValue)")
        if let responseText = remoteTask.responseText, !responseText.isEmpty {
            print("[OpenClaw] response: \(responseText)")
        }
        if let error = remoteTask.error, !error.isEmpty {
            print("[OpenClaw] task error: \(error)")
        }

        let existingPreview = openClawTasks.first(where: { $0.id == remoteTask.id })?.previewJPEGData
        let now = Date()
        let item = OpenClawTaskItem(
            id: remoteTask.id,
            status: remoteTask.status,
            executor: remoteTask.executor ?? "unknown",
            prompt: remoteTask.prompt,
            stepKey: remoteTask.stepKey ?? "",
            stepLabel: remoteTask.stepLabel ?? "",
            stepIndex: remoteTask.stepIndex ?? 0,
            totalSteps: remoteTask.totalSteps ?? 0,
            progress: remoteTask.progress ?? 0,
            createdAt: parseTaskDate(remoteTask.createdAt) ?? now,
            updatedAt: parseTaskDate(remoteTask.updatedAt) ?? now,
            responseText: remoteTask.responseText ?? "",
            errorText: remoteTask.error ?? "",
            previewJPEGData: existingPreview
        )
        upsertOpenClawTask(item)

        switch remoteTask.status {
        case .queued:
            isOpenClawBusy = true
            if let stepLabel = remoteTask.stepLabel, !stepLabel.isEmpty {
                openClawStatusMessage = "OpenClaw 排队中: \(stepLabel)"
            } else {
                openClawStatusMessage = "OpenClaw 任务排队中..."
            }
        case .processing:
            isOpenClawBusy = true
            if let stepLabel = remoteTask.stepLabel, !stepLabel.isEmpty {
                openClawStatusMessage = "OpenClaw 处理中: \(stepLabel)"
            } else {
                openClawStatusMessage = "OpenClaw 正在处理中..."
            }
        case .completed:
            isOpenClawBusy = false
            openClawLastResponse = remoteTask.responseText ?? ""
            openClawStatusMessage = "OpenClaw 已完成"
        case .failed:
            isOpenClawBusy = false
            openClawLastResponse = ""
            openClawStatusMessage = "OpenClaw 失败: \(remoteTask.error ?? "未知错误")"
        }
    }

    private func upsertOpenClawTask(_ item: OpenClawTaskItem) {
        if let index = openClawTasks.firstIndex(where: { $0.id == item.id }) {
            openClawTasks[index] = item
        } else {
            openClawTasks.insert(item, at: 0)
        }
        if openClawTasks.count > 8 {
            openClawTasks = Array(openClawTasks.prefix(8))
        }
    }

    private func parseTaskDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private func currentOpenClawJPEGData() -> Data? {
        if let lastProcessedFrame, !lastProcessedFrame.isEmpty {
            return lastProcessedFrame
        }

        return capturedImageLeft?.jpegData(compressionQuality: 0.85)
    }
}

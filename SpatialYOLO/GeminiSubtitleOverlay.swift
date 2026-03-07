//
//  GeminiSubtitleOverlay.swift
//  SpatialYOLO
//
//  AI 字幕叠加层：
//    GeminiSubtitleOverlay      — HUD 风格实时转录（麻将模式使用）
//    TranslationSubtitleOverlay — 语音转写浮动字幕（AI Live 模式使用）
//

import SwiftUI

/// Gemini 回复字幕叠加层（HUD 风格）
/// 实时显示 AI 语音转写文本，自动滚动到最新内容
struct GeminiSubtitleOverlay: View {
    @EnvironmentObject var appModel: AppModel
    let geminiService: any RealtimeAIService

    /// 视频区域尺寸（固定 960×540）
    private let videoWidth:  CGFloat = 960
    private let videoHeight: CGFloat = 540

    /// 文本版本号（用于触发滚动）
    @State private var textVersion: Int = 0
    @State private var lastTextLength: Int = 0
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        let text = geminiService.responseText

        VStack(alignment: .leading, spacing: 4) {
            // 标签头
            Text(appModel.language == .english ? "AI TRANSCRIPT:" : "AI 对话转录:")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Color.hudCyan.opacity(0.7))
                .padding(.horizontal, 12)
                .padding(.top, 8)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(text)
                            .font(.system(size: 20, weight: .medium, design: .monospaced))
                            .foregroundColor(Color.hudCyan)
                            .multilineTextAlignment(.leading)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: videoWidth * 0.8, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)

                        Color.clear
                            .frame(height: 1)
                            .id("anchor")
                    }
                }
                .frame(maxWidth: videoWidth * 0.8, maxHeight: videoHeight * 0.3)
                .onChange(of: textVersion) {
                    proxy.scrollTo("anchor", anchor: .bottom)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.hudCyan.opacity(0.3), lineWidth: 1)
                )
        )
        .padding(.bottom, 16)
        .opacity(text.isEmpty ? 0 : 1)
        .onAppear {
            startPolling()
        }
        .onDisappear {
            pollTask?.cancel()
        }
    }

    /// 轮询检测文本变化（避免 any protocol 无法触发 onChange 的问题）
    private func startPolling() {
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                let currentLength = geminiService.responseText.count
                if currentLength != lastTextLength {
                    lastTextLength = currentLength
                    textVersion += 1
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }
    }
}

// MARK: - 语音转写浮动字幕（AI Live 模式）

/// 独立悬浮的语音转写字幕叠加层
/// 显示 AI 的语音转写内容，自动滚动到最新文字
/// 用于 AI Live 模式，字幕在用户正前方偏下位置独立悬浮
struct TranslationSubtitleOverlay: View {
    let geminiService: any RealtimeAIService

    @State private var textVersion: Int = 0
    @State private var lastTextLength: Int = 0
    @State private var pollTask: Task<Void, Never>?
    @State private var displayedText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            if !displayedText.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(displayedText)
                                .font(.system(size: 24, weight: .medium))
                                .foregroundColor(.white)
                                .multilineTextAlignment(.leading)
                                .lineSpacing(6)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 800, alignment: .leading)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 14)

                            Color.clear
                                .frame(height: 1)
                                .id("subtitleAnchor")
                        }
                    }
                    .frame(maxWidth: 860, maxHeight: 120)
                    .onChange(of: textVersion) {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 50_000_000)
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("subtitleAnchor", anchor: .bottom)
                            }
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.72))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        )
                )
                .padding(.bottom, 20)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: displayedText.isEmpty)
        .onAppear { startPolling() }
        .onDisappear { pollTask?.cancel() }
    }

    private func startPolling() {
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                let currentText = geminiService.responseText
                if currentText.count != lastTextLength {
                    lastTextLength = currentText.count
                    displayedText = currentText
                    textVersion += 1
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }
    }
}


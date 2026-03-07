//
//  GeminiSubtitleOverlay.swift
//  SpatialYOLO
//
//  AI 字幕叠加层：
//    GeminiSubtitleOverlay      — HUD 风格实时转录（麻将模式使用）
//    TranslationSubtitleOverlay — 双语翻译字幕（AI Live 模式使用）
//

import SwiftUI

/// Gemini 回复字幕叠加层（HUD 风格）
/// 实时显示 AI 语音转写文本，自动滚动到最新内容
struct GeminiSubtitleOverlay: View {
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
            Text("AI TRANSCRIPT:")
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

// MARK: - 双语翻译字幕（AI Live 模式）

/// 实时双语翻译字幕叠加层
/// 显示 AI 翻译的中英双语内容：第一行中文、第二行英文
/// 用于 AI Live 模式，字幕在画面底部醒目显示
struct TranslationSubtitleOverlay: View {
    let geminiService: any RealtimeAIService

    var body: some View {
        let chinese = geminiService.subtitleChinese
        let english = geminiService.subtitleEnglish
        let hasContent = !chinese.isEmpty || !english.isEmpty

        VStack(spacing: 0) {
            if hasContent {
                VStack(alignment: .center, spacing: 8) {
                    // 第一行：中文
                    if !chinese.isEmpty {
                        Text(chinese)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // 第二行：英文
                    if !english.isEmpty {
                        Text(english)
                            .font(.system(size: 22, weight: .regular))
                            .foregroundColor(.white.opacity(0.88))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.72))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        )
                )
                .frame(maxWidth: 860)
                .padding(.bottom, 20)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: chinese)
        .animation(.easeInOut(duration: 0.25), value: english)
    }
}

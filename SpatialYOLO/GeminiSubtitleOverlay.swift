//
//  GeminiSubtitleOverlay.swift
//  SpatialYOLO
//
//  JARVIS HUD 风格 AI 字幕叠加层（打字机效果）
//

import SwiftUI

/// Gemini 回复字幕叠加层（HUD 风格）
/// 以打字机效果逐字显示在视频画面底部，历史字幕持续保留
struct GeminiSubtitleOverlay: View {
    let geminiService: any RealtimeAIService

    /// 视频区域尺寸（固定 960×540）
    private let videoWidth:  CGFloat = 960
    private let videoHeight: CGFloat = 540

    /// 当前已显示的字符数（打字机进度，只增不减）
    @State private var displayedCount: Int = 0
    /// 打字机定时器
    @State private var typewriterTask: Task<Void, Never>?

    private let charInterval: TimeInterval = 0.04

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 标签头
            Text("AI TRANSCRIPT:")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Color.hudCyan.opacity(0.7))
                .padding(.horizontal, 12)
                .padding(.top, 8)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    Text(displayedText)
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                        .foregroundColor(Color.hudCyan)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(4)
                        .frame(maxWidth: videoWidth * 0.8, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                        .id("bottom")
                }
                .frame(maxWidth: videoWidth * 0.8, maxHeight: videoHeight * 0.2)
                .onChange(of: displayedCount) {
                    withAnimation(.linear(duration: 0.05)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
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
        .opacity(displayedText.isEmpty ? 0 : 1)
        .onAppear {
            startTypewriter()
        }
    }

    // MARK: - 打字机逻辑

    private var displayedText: String {
        let fullText = geminiService.responseText
        guard !fullText.isEmpty, displayedCount > 0 else { return "" }
        let count = min(displayedCount, fullText.count)
        let endIndex = fullText.index(fullText.startIndex, offsetBy: count)
        return String(fullText[fullText.startIndex..<endIndex])
    }

    private func startTypewriter() {
        guard typewriterTask == nil else { return }
        typewriterTask = Task { @MainActor in
            while !Task.isCancelled {
                let fullText = geminiService.responseText

                if displayedCount >= fullText.count {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }

                displayedCount += 1
                try? await Task.sleep(nanoseconds: UInt64(charInterval * 1_000_000_000))
            }
            typewriterTask = nil
        }
    }
}

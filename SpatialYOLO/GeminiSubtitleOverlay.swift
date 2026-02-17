//
//  GeminiSubtitleOverlay.swift
//  SpatialYOLO
//
//  Created by Claude on 2025/4/15.
//

import SwiftUI

/// Gemini 回复字幕叠加层
/// 以打字机效果逐字显示在视频画面底部，高度不超过视频区域 20%，宽度不超过 80%
/// 历史字幕持续保留，新回复 append 到后面，始终滚动到最新内容
struct GeminiSubtitleOverlay: View {
    let geminiService: any RealtimeAIService

    /// 视频区域尺寸（DualCameraView 固定 960x540）
    private let videoWidth: CGFloat = 960
    private let videoHeight: CGFloat = 540

    /// 当前已显示的字符数（打字机进度，只增不减）
    @State private var displayedCount: Int = 0
    /// 打字机定时器
    @State private var typewriterTask: Task<Void, Never>?

    /// 打字速度
    private let charInterval: TimeInterval = 0.04

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                Text(displayedText)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.white)
                    .shadow(color: .black, radius: 4, x: 0, y: 2)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(4)
                    .frame(maxWidth: videoWidth * 0.8, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .id("bottom")
            }
            .frame(maxWidth: videoWidth * 0.8, maxHeight: videoHeight * 0.2)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.black.opacity(0.55))
            )
            .padding(.bottom, 16)
            .onChange(of: displayedCount) {
                withAnimation(.linear(duration: 0.05)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
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

    /// 打字机协程：持续运行，追赶 responseText 的增长
    private func startTypewriter() {
        guard typewriterTask == nil else { return }
        typewriterTask = Task { @MainActor in
            while !Task.isCancelled {
                let fullText = geminiService.responseText

                if displayedCount >= fullText.count {
                    // 已追上，等待新内容
                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                    continue
                }

                // 推进一个字符
                displayedCount += 1
                try? await Task.sleep(nanoseconds: UInt64(charInterval * 1_000_000_000))
            }
            typewriterTask = nil
        }
    }
}

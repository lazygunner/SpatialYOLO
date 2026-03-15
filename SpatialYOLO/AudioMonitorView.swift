//
//  AudioMonitorView.swift
//  SpatialYOLO
//
//  音频输入监测视图：实时波形可视化 + 本地语音转文字
//  独立开关，不随 Live API 联动
//

import SwiftUI

struct AudioMonitorView: View {
    let monitor: AudioInputMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerView

            // ── 波形（仅 active 时显示）──────────────────────────
            if monitor.isActive {
                WaveformBars(bars: monitor.waveformBars)
                    .frame(height: 34)
                    .transition(.opacity.combined(with: .move(edge: .top)))

                // ── 本地 STT 文字：历史记录 + 当前输入分区显示 ─────────────
                VStack(alignment: .leading, spacing: 6) {
                    historySection
                    liveInputSection
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: monitor.isActive)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.black.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.hudCyan.opacity(0.2), lineWidth: 1)
                )
        )
        .onAppear {
            monitor.scheduleAutoStart(after: 1.2)
        }
    }

    // MARK: - Helpers

    private var headerView: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(sttDotColor)
                .frame(width: 6, height: 6)

            Text("ENV LISTEN")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Color.hudCyan.opacity(0.6))

            Spacer()

            Text(sttStatusLabel)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(sttDotColor.opacity(0.85))
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if !monitor.committedLines.isEmpty {
            Text("HISTORY")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.45))
                .padding(.horizontal, 2)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(monitor.committedLines.enumerated()), id: \.offset) { index, line in
                            historyLine(line, index: index)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("audioTranscriptAnchor")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                }
                .frame(height: 78)
                .background(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.hudCyan.opacity(0.15), lineWidth: 1)
                )
                .cornerRadius(3)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: historySignature)
                .onAppear {
                    proxy.scrollTo("audioTranscriptAnchor", anchor: .bottom)
                }
                .onChange(of: historySignature) {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo("audioTranscriptAnchor", anchor: .bottom)
                    }
                }
            }
        }
    }

    private var liveInputSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LIVE INPUT")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Color.hudCyan.opacity(0.65))
                .padding(.horizontal, 2)

            Text(monitor.localTranscript.isEmpty ? "Listening..." : monitor.localTranscript)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundColor(monitor.localTranscript.isEmpty ? Color.hudCyan.opacity(0.45) : Color.hudCyan.opacity(0.92))
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.hudCyan.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.hudCyan.opacity(0.25), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private func historyLine(_ line: String, index: Int) -> some View {
        Text(line)
            .font(.system(size: 13, weight: .regular, design: .monospaced))
            .foregroundColor(.white.opacity(0.88))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .id(index)
    }

    private var historySignature: String {
        monitor.committedLines.joined(separator: "\n")
    }

    private var sttDotColor: Color {
        switch monitor.sttStatus {
        case .active:       return Color(red: 0.3, green: 0.9, blue: 0.5)
        case .requesting:   return Color.hudAmber
        case .unavailable:  return .gray
        case .error:        return .red
        case .idle:         return .gray
        }
    }

    private var sttStatusLabel: String {
        switch monitor.sttStatus {
        case .active:       return "STT  LIVE"
        case .requesting:   return "STT  INIT"
        case .unavailable:  return "STT  N/A"
        case .error:        return "STT  ERR"
        case .idle:         return "STT  OFF"
        }
    }
}

// MARK: - 波形条形图（Canvas 渲染，高效）

private struct WaveformBars: View {
    let bars: [Float]

    var body: some View {
        Canvas { context, size in
            let count = bars.count
            guard count > 0 else { return }

            let totalGap = CGFloat(count - 1) * 1.5
            let barW = max(1, (size.width - totalGap) / CGFloat(count))
            let midY  = size.height / 2

            for i in 0..<count {
                let level = CGFloat(bars[i])
                let halfH = max(1.5, level * midY)
                let x = CGFloat(i) * (barW + 1.5)
                let rect = CGRect(x: x, y: midY - halfH, width: barW, height: halfH * 2)

                let color: Color
                if level < 0.15 {
                    color = Color.hudCyan.opacity(0.25 + Double(level) * 2)
                } else if level < 0.65 {
                    let t = Double((level - 0.15) / 0.5)
                    color = Color(
                        hue: 0.51 - t * 0.08,
                        saturation: 0.7 + t * 0.25,
                        brightness: 0.6 + t * 0.35
                    )
                } else {
                    let t = Double((level - 0.65) / 0.35)
                    color = Color(
                        hue: 0.43 - t * 0.12,
                        saturation: 0.9,
                        brightness: 0.9 + t * 0.1
                    )
                }

                context.fill(
                    Path(roundedRect: rect, cornerRadius: barW / 2),
                    with: .color(color)
                )
            }
        }
    }
}

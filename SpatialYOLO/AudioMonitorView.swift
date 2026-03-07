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

            // ── 标题行 + 开关按钮 ────────────────────────────────
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

                // 独立开关按钮
                Button(action: { monitor.toggle() }) {
                    Text(monitor.isActive ? "STOP" : "START")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(monitor.isActive ? Color.hudAmber : Color.hudCyan)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(monitor.isActive ? Color.hudAmber : Color.hudCyan, lineWidth: 1)
                                .opacity(0.7)
                        )
                }
                .buttonStyle(.plain)
            }

            // ── 波形（仅 active 时显示）──────────────────────────
            if monitor.isActive {
                WaveformBars(bars: monitor.waveformBars)
                    .frame(height: 34)
                    .transition(.opacity.combined(with: .move(edge: .top)))

                // ── 本地 STT 文字 ─────────────────────────────────
                if !displayText.isEmpty {
                    Text(displayText)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.white.opacity(0.88))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.hudCyan.opacity(0.15), lineWidth: 1)
                        )
                        .cornerRadius(3)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: displayText)
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
    }

    // MARK: - Helpers

    private var displayText: String {
        if !monitor.localTranscript.isEmpty { return monitor.localTranscript }
        return monitor.committedTranscript
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

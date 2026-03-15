//
//  ProjectDetailView.swift
//  SpatialYOLO
//
//  项目详情：查看历史 AI Live 会话的视频帧和识别结果
//

import SwiftUI

struct ProjectDetailView: View {
    @EnvironmentObject var appModel: AppModel
    @State private var session: SessionInfo
    @State private var frames: [FrameInfo] = []
    @State private var selectedFrame: FrameInfo?
    @State private var isLoading: Bool = true
    @State private var isProcessing: Bool = false
    @Environment(\.dismiss) private var dismiss
    
    init(session: SessionInfo) {
        _session = State(initialValue: session)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航栏
            HStack {
                Button {
                    NotificationCenter.default.post(name: .refreshProjectList, object: nil)
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text(appModel.language == .english ? "Back" : "返回")
                    }
                    .font(.body)
                    .foregroundColor(.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 10))
                    .hoverEffect()
                }
                .buttonStyle(.plain)

                Spacer()

                VStack(spacing: 2) {
                    Text(appModel.language == .english ? "Session \(session.id)" : "会话 \(session.id)")
                        .font(.headline)
                    
                    HStack(spacing: 4) {
                        Text(formattedDate)
                        
                        if !session.locationName.isEmpty && session.locationName != "未知地点" {
                            Text("·")
                            Image(systemName: "location.fill")
                                .font(.system(size: 10))
                            Text(session.locationName)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(appModel.language == .english ? "\(frames.count) Frames" : "\(frames.count) 帧")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(SessionRecorder.formattedSize(session.sizeBytes))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Capsule().fill(.ultraThinMaterial))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            // 主内容区域
            if isLoading {
                VStack {
                    Spacer()
                    ProgressView(appModel.language == .english ? "Loading memories..." : "加载回忆数据...")
                        .padding()
                    Spacer()
                }
                .frame(maxHeight: 300)
            } else if session.status == .pending || session.status == .processing {
                // 自动处理中状态，显示居中进度
                VStack(spacing: 20) {
                    Spacer()
                    ProgressView()
                        .controlSize(.extraLarge)
                        .tint(.purple)
                    
                    Text(session.status == .pending
                         ? (appModel.language == .english ? "Waiting to process..." : "等待处理...")
                         : (appModel.language == .english ? "Organizing your memory..." : "正在为您整理回忆..."))
                        .font(.headline)
                    Text(appModel.language == .english
                         ? "The system is merging similar scenes and generating a dedicated cartoon cover."
                         : "系统正在自动合并相似场景并为您生成专属卡通封面。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Spacer()
                }
                .frame(maxHeight: .infinity)
                .onAppear {
                    startPollingStatus()
                }
            } else if let frame = selectedFrame {
                // 选中帧的详情
                HStack(spacing: 16) {
                    // 左侧：大图 (显示当前选中的原始视频帧)
                    ZStack(alignment: .topLeading) {
                        if let data = try? Data(contentsOf: frame.imageURL),
                           let uiImage = UIImage(data: data) {
                            
                            // 总是显示原始视频帧
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 500, maxHeight: 350)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .shadow(radius: 4)
                        }
                    }

                    // 右侧：检测结果 + AI 回复
                    VStack(alignment: .leading, spacing: 12) {
                        // 检测上下文
                        VStack(alignment: .leading, spacing: 4) {
                            Text(appModel.language == .english ? "Detections" : "检测结果")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)

                            ScrollView(.vertical, showsIndicators: true) {
                                Text(frame.context.isEmpty
                                     ? (appModel.language == .english ? "No detection data" : "无检测数据")
                                     : frame.context)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxWidth: 300, maxHeight: frame.hasAIResponse ? 140 : 280)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.ultraThinMaterial)
                            )
                        }

                        // AI 回复文本
                        if frame.hasAIResponse {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Image(systemName: "sparkles")
                                        .foregroundColor(.purple)
                                    Text(appModel.language == .english ? "AI Response" : "AI 回复")
                                        .font(.caption.bold())
                                        .foregroundColor(.purple)
                                }

                                ScrollView(.vertical, showsIndicators: true) {
                                    Text(frame.aiResponse)
                                        .font(.system(size: 13))
                                        .foregroundColor(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxWidth: 300, maxHeight: 140)
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.purple.opacity(0.08))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.purple.opacity(0.2), lineWidth: 1)
                                        )
                                )
                            }
                        }
                    }
                }
                .padding(20)
            } else if session.status == .completed,
                       let cUrlStr = session.cartoonImageURL?.absoluteString,
                       let cUrl = URL(string: cUrlStr),
                       let data = try? Data(contentsOf: cUrl),
                       let uiImage = UIImage(data: data) {
                
                // 处理已完成且未选中具体帧时，展示卡通封面
                VStack(spacing: 20) {
                    Spacer()
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 600, maxHeight: 400)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(radius: 10)
                        
                        HStack(spacing: 6) {
                            Image(systemName: "wand.and.stars")
                            Text(appModel.language == .english ? "Memory Cover" : "我的回忆封面")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.orange))
                        .offset(x: 12, y: 12)
                    }
                    
                    Text(appModel.language == .english
                         ? "This memory has already been processed. Choose a specific moment below to review it."
                         : "由于您已经处理了这段回忆，您可以从下方选择具体的瞬间进行回顾。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                }
                .frame(maxHeight: .infinity)
                
            } else {
                ContentUnavailableView(
                    appModel.language == .english ? "No frames available" : "暂无帧数据",
                    systemImage: "photo"
                )
                .frame(maxHeight: 300)
            }

            Divider()

            // 底部：帧缩略图滚动条 (仅在有数据或者已处理时显示)
            if !frames.isEmpty && session.status != .pending {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(frames) { frame in
                            FrameThumbnail(
                                frame: frame,
                                isSelected: selectedFrame?.id == frame.id
                            )
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedFrame = frame
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .frame(height: 100)
                .background(.ultraThinMaterial)
            }
        }
        .frame(width: 880, height: 600)
        .onAppear {
            loadFrames()
        }
    }

    private func loadFrames() {
        Task {
            // 如果已经被处理过了，直接读取现有的（因为在 processSession 里已经合并并删除了废帧）
            // 如果 pending，也先加载全量帧做个背景或统计
            let needGroup = (session.status == .pending)
            let loadedFrames = await SessionRecorder.listFrames(in: session.directory, groupSimilar: needGroup)
            
            await MainActor.run {
                frames = loadedFrames
                // 如果已经有卡通图了，默认展示卡通图封面（即 selectedFrame = nil）
                // 否则选中第一帧展示内容
                if session.cartoonImageURL != nil {
                    selectedFrame = nil
                } else {
                    selectedFrame = loadedFrames.first
                }
                isLoading = false
            }
        }
    }
    
    private func processMemory() {
        // 由于现在已经自动化，此手动方法仅作为备用。
        if isProcessing { return }
        isProcessing = true
        Task {
            await SessionRecorder.processSession(session)
            refreshSessionData()
            isProcessing = false
        }
    }
    
    private func refreshSessionData() {
        let updatedSessions = SessionRecorder.listSessions()
        if let updated = updatedSessions.first(where: { $0.id == session.id }) {
            self.session = updated
            if session.status == .completed {
                loadFrames()
            }
        }
    }

    private func startPollingStatus() {
        Task {
            while session.status != .completed {
                // 每 2 秒从本地文件刷新一次元数据
                try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
                
                await MainActor.run {
                    refreshSessionData()
                    print("[详情] 轮询中... 当前状态: \(session.status)")
                }
            }
            print("[详情] 轮询结束，处理已完成。")
        }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.locale = appModel.language == .english ? Locale(identifier: "en_US") : Locale(identifier: "zh_CN")
        formatter.dateFormat = appModel.language == .english ? "MMM d, yyyy h:mm a" : "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: session.startTime)
    }
}

// MARK: - 帧缩略图

struct FrameThumbnail: View {
    let frame: FrameInfo
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let data = try? Data(contentsOf: frame.imageURL),
               let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 80, height: 60)
            }

            // AI 回复标记（小紫点）
            if frame.hasAIResponse {
                Circle()
                    .fill(LinearGradient(colors: [.purple, .pink], startPoint: .top, endPoint: .bottom))
                    .frame(width: 8, height: 8)
                    .offset(x: -2, y: 2)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
        )
        .shadow(color: isSelected ? .blue.opacity(0.3) : .clear, radius: 4)
    }
}

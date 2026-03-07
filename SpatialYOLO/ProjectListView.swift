//
//  ProjectListView.swift
//  SpatialYOLO
//
//  项目列表：水平滚动显示历史 AI Live 会话
//

import SwiftUI

struct ProjectListView: View {
    @State private var sessions: [SessionInfo] = []
    @State private var totalSize: Int64 = 0
    @State private var sessionToDelete: SessionInfo?
    @State private var showingDeleteAlert = false

    /// 点击项目卡片的回调
    var onSelect: ((SessionInfo) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 标题行
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(.secondary)
                Text("我的回忆")
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                // 总占用空间
                Text("共 \(sessions.count) 个 · \(SessionRecorder.formattedSize(totalSize))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)

            if sessions.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("暂无回忆")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 30)
                    Spacer()
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(sessions) { session in
                            SessionCard(session: session, onDelete: {
                                sessionToDelete = session
                                showingDeleteAlert = true
                            })
                            .onTapGesture {
                                onSelect?(session)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }
        }
        .alert("删除会话", isPresented: $showingDeleteAlert) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                if let session = sessionToDelete {
                    deleteSession(session)
                }
            }
        } message: {
            Text("确定要删除这个历史会话吗？此操作不可恢复。")
        }
        .onAppear {
            refreshData()
        }
    }

    private func deleteSession(_ session: SessionInfo) {
        SessionRecorder.deleteSession(session)
        withAnimation {
            sessions.removeAll { $0.id == session.id }
            totalSize = SessionRecorder.totalStorageSize()
        }
    }

    private func refreshData() {
        sessions = SessionRecorder.listSessions()
        totalSize = SessionRecorder.totalStorageSize()
    }
}

// MARK: - 会话卡片

struct SessionCard: View {
    let session: SessionInfo
    var onDelete: (() -> Void)?

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: session.startTime)
    }

    var body: some View {
        VStack(spacing: 8) {
            // 缩略图
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.gray.opacity(0.15))
                        .frame(width: 150, height: 100)

                    // 优先显示生成的卡通图封面，如果没有则显示第一帧缩略图
                    if let cartoonURL = session.cartoonImageURL,
                       let data = try? Data(contentsOf: cartoonURL),
                       let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 150, height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else if let thumbURL = session.thumbnailURL,
                       let data = try? Data(contentsOf: thumbURL),
                       let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 150, height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Image(systemName: "video.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary.opacity(0.4))
                    }
                }

                // 删除按钮
                Button {
                    onDelete?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .shadow(radius: 2)
                }
                .buttonStyle(.plain)
                .contentShape(.hoverEffect, Circle())
                .hoverEffect()
                .offset(x: 4, y: -4)
            }

            // 元信息
            VStack(alignment: .leading, spacing: 4) {
                Text(formattedTime)
                    .font(.caption2.bold())
                    .foregroundColor(.primary)
                
                if !session.locationName.isEmpty && session.locationName != "未知地点" {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 10))
                        Text(session.locationName)
                            .lineLimit(1)
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.blue)
                }

                HStack(spacing: 4) {
                    // 状态徽标
                    switch session.status {
                    case .pending:
                        Text("待处理")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                    case .processing:
                        Text("处理中")
                            .font(.system(size: 9))
                            .foregroundColor(.blue)
                    case .completed:
                        Text("已处理")
                            .font(.system(size: 9))
                            .foregroundColor(.green)
                    }
                    Text("·")
                    Text("\(session.frameCount) 帧")
                    Text("·")
                    Text(SessionRecorder.formattedSize(session.sizeBytes))
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .frame(width: 150)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

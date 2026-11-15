import SwiftUI
import UIKit

// 由 HomeView.swift 拆分 (v5.2: 每个功能一个文件, 方便定位问题)

/// 粘贴链接直接播 (借鉴 VLC 的网络串流入口): 贴一个 mp4/m3u8 直链立刻播,
/// 播完可像站内视频一样收藏 (收藏的是链接快照, 在片库里能再打开)
struct LinkPlayView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var note = ""
    @State private var playItem: VideoItem? = nil

    var body: some View {
        Form {
            Section {
                TextField("粘贴视频直链 (mp4 / m3u8)", text: $link)
                    .autocapitalization(.none)
                    .autocorrectionDisabled(true)
                Button("从剪贴板粘贴") {
                    if let s = UIPasteboard.general.string {
                        link = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            } footer: {
                Text("支持 http/https 的 mp4、m3u8 直链。在外面看到好视频, 贴进来就能看。")
            }
            if !note.isEmpty {
                Section { Text(note).font(.callout).foregroundColor(.red) }
            }
            Section {
                Button("开始播放") { start() }
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle("粘贴链接播放")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("取消") { dismiss() }
            }
        }
        .background(
            NavigationLink(isActive: Binding(
                get: { playItem != nil },
                set: { if !$0 { playItem = nil } }
            )) {
                if let v = playItem { PlayerView(video: v) }
            } label: { EmptyView() }
            .hidden()
        )
    }

    private func start() {
        let s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("http"), s.contains(".mp4") || s.contains(".m3u8") else {
            note = "链接不对: 需要 http 开头、包含 .mp4 或 .m3u8 的视频直链"
            return
        }
        note = ""
        playItem = VideoItem(video_id: "link:" + String(abs(s.hashValue)),
                             title: "外部链接视频", author: "", thumbnail_url: nil,
                             duration: s, source_section: nil, views: nil, has_mp4: true,
                             needs_rescrape: nil, video_url: nil, vote_up: nil, vote_down: nil,
                             created_at: nil, monsnode_video_id: nil, source_page: nil,
                             playable: true, vip_early: nil)
    }
}

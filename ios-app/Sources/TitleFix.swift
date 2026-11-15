import SwiftUI
import UIKit

// 由 Features21.swift 拆分 (v5.2: 每个功能一个文件, 方便定位问题)

// MARK: - 标题纠正 (v5.1 标题党治理, 学 DeArrow): 提名更准确的标题, 投票满 5 票自动生效, 站主可直接通过/驳回
struct TitleSuggestion: Decodable {
    var id: FlexInt?
    var video_id: String?
    var current_title: String?
    var suggested_title: String?
    var username: String?
    var votes: FlexInt?
    var my_voted: Bool?
    var created_at: String?
    var sid: Int { id?.value ?? 0 }
    var voteCount: Int { votes?.value ?? 0 }
}

enum TitleAPI {
    struct Res: Decodable { var ok: Bool?; var message: String?; var votes: FlexInt? }
    private static var token: String { Session.shared.loginToken ?? "" }

    static func suggest(videoId: String, title: String) async -> String {
        let rows: [Res] = (try? await SB.rpc("suggest_title", params: ["p_token": token, "p_video_id": videoId, "p_title": title])) ?? []
        return rows.first?.message ?? "提交失败"
    }
    static func list() async -> [TitleSuggestion] {
        let rows: [TitleSuggestion] = (try? await SB.rpc("list_title_suggestions", params: ["p_token": token, "p_limit": 50])) ?? []
        return rows
    }
    static func vote(_ id: Int) async -> String {
        let rows: [Res] = (try? await SB.rpc("vote_title", params: ["p_token": token, "p_suggestion_id": id])) ?? []
        return rows.first?.message ?? "投票失败"
    }
    static func moderate(_ id: Int, action: String) async -> String {
        let rows: [Res] = (try? await SB.rpc("moderate_title", params: ["p_token": token, "p_id": id, "p_action": action])) ?? []
        return rows.first?.message ?? "操作失败"
    }
}

/// 标题纠正列表: 待投票的提名, 谁都能投票; 满 5 票自动生效
struct TitleFixView: View {
    @EnvironmentObject var session: Session
    @State private var items: [TitleSuggestion] = []
    @State private var note = ""
    @State private var navVideo: VideoItem? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("遇到标题党就在播放页点「纠正标题」提名一个准确的标题，大家投票，满 5 票自动换上。站主可直接通过或驳回。")
                    .font(.caption).foregroundColor(Theme.sub)
                if !note.isEmpty {
                    Text(note).font(.caption).foregroundColor(Theme.gold2)
                }
                if items.isEmpty {
                    Text("暂无待纠正的标题")
                        .foregroundColor(Theme.sub)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                }
                ForEach(items, id: \.sid) { s in
                    row(s)
                }
            }
            .padding(14)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("标题纠正")
        .navigationBarTitleDisplayMode(.inline)
        .background(
            NavigationLink(isActive: Binding(get: { navVideo != nil },
                                             set: { if !$0 { navVideo = nil } })) {
                if let v = navVideo { PlayerView(video: v) }
            } label: { EmptyView() }
                .hidden()
        )
        .task { items = await TitleAPI.list() }
    }

    private func row(_ s: TitleSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("现标题：" + (s.current_title ?? "（无标题）"))
                .font(.system(size: 12.5)).foregroundColor(Theme.sub).lineLimit(2)
            Text("提名：" + (s.suggested_title ?? ""))
                .font(.system(size: 14, weight: .semibold)).lineLimit(2)
            HStack(spacing: 8) {
                Text("@" + (s.username ?? "") + " 提名")
                    .font(.caption2).foregroundColor(Theme.sub)
                Spacer()
                Button {
                    Task {
                        note = await TitleAPI.vote(s.sid)
                        items = await TitleAPI.list()
                    }
                } label: {
                    Label("\(s.voteCount)/5", systemImage: (s.my_voted ?? false) ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(.system(size: 12.5, weight: .bold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background((s.my_voted ?? false) ? Theme.gold : Theme.surface2)
                        .foregroundColor((s.my_voted ?? false) ? .black : Theme.text)
                        .cornerRadius(99)
                }
                .buttonStyle(.plain)
                Button("看视频") {
                    Task {
                        if let vid = s.video_id,
                           let v = (await FeedService.fetchByIds([vid])).first {
                            navVideo = v
                        }
                    }
                }
                .font(.system(size: 12.5, weight: .semibold)).foregroundColor(Theme.gold2)
            }
            if session.isAdmin || session.isOwner {
                HStack(spacing: 10) {
                    Button("通过（立即生效）") {
                        Task {
                            note = await TitleAPI.moderate(s.sid, action: "apply")
                            items = await TitleAPI.list()
                        }
                    }
                    .font(.system(size: 12.5, weight: .bold)).foregroundColor(.green)
                    Button("驳回", role: .destructive) {
                        Task {
                            note = await TitleAPI.moderate(s.sid, action: "reject")
                            items = await TitleAPI.list()
                        }
                    }
                    .font(.system(size: 12.5)).foregroundColor(.red.opacity(0.85))
                    Spacer()
                }
            }
        }
        .padding(12)
        .glassPanel(14)
    }
}

/// 提名新标题 (播放页「纠正标题」打开)
struct TitleSuggestView: View {
    let video: VideoItem
    @Environment(\.dismiss) private var dismiss
    @State private var newTitle = ""
    @State private var note = ""
    @State private var done = false

    var body: some View {
        Form {
            Section(header: Text("现在的标题")) {
                Text(video.displayTitle).font(.system(size: 14))
            }
            Section(header: Text("提名一个准确的标题（4~60 字）"),
                    footer: Text("提交后进入投票，满 5 票自动换上；乱提名站主会驳回。")) {
                TextField("新标题", text: $newTitle)
                    .autocorrectionDisabled(true)
            }
            if !note.isEmpty {
                Section { Text(note).foregroundColor(Theme.gold2) }
            }
            Section {
                Button(done ? "已提交 ✓" : "提交提名") {
                    Task {
                        let t = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        note = await TitleAPI.suggest(videoId: video.video_id, title: t)
                        if note.contains("已提交") { done = true }
                    }
                }
                .disabled(done || newTitle.trimmingCharacters(in: .whitespaces).count < 4)
                Button("关闭") { dismiss() }
            }
        }
        .navigationTitle("纠正标题")
        .navigationBarTitleDisplayMode(.inline)
    }
}

import SwiftUI
import UIKit

// 由 AdminOps.swift 拆分 (v5.2: 每个功能一个文件, 方便定位问题)

func msgSummary(_ raw: String) -> String {
    switch MsgContent.parse(raw) {
    case .text(let s): return s
    case .sticker(let e): return "表情 " + e
    case .voice: return "🎤 语音消息"
    case .loc(let n, _, _): return "📍 " + n
    case .img: return "🖼 图片"
    case .video: return "🎬 视频"
    case .share(_, let t, _): return "🎬 分享视频 《" + t + "》"
    case .file(_, let n, _): return "📎 " + n
    }
}

struct AdminMessagesView: View {
    @State private var msgs: [AdminAPI.RecentMsg] = []
    var body: some View {
        List {
            ForEach(Array(msgs.enumerated()), id: \.offset) { _, m in
                VStack(alignment: .leading, spacing: 3) {
                    Text("@\(m.from_user ?? "?") → @\(m.to_user ?? "?")").font(.subheadline).bold()
                    Text(msgSummary(m.content ?? "")).font(.callout).lineLimit(3)
                    Text(String((m.created_at ?? "").prefix(16))).font(.caption2).foregroundColor(.secondary)
                }
            }
            if msgs.isEmpty { Text("暂无数据").foregroundColor(.secondary) }
        }
        .navigationTitle("私信总览")
        .task { msgs = await AdminAPI.recentMessages() }
    }
}

struct AdminBansView: View {
    @State private var bans: [AdminAPI.BanRow] = []
    var body: some View {
        List {
            ForEach(bans) { b in
                VStack(alignment: .leading, spacing: 3) {
                    Text("@" + (b.username ?? "?")).font(.subheadline).bold()
                    if let r = b.reason, !r.isEmpty { Text(r).font(.callout) }
                    Text(String((b.created_at ?? "").prefix(16))).font(.caption2).foregroundColor(.secondary)
                }
            }
            if bans.isEmpty { Text("暂无封禁记录").foregroundColor(.secondary) }
        }
        .navigationTitle("封禁记录")
        .task { bans = await AdminAPI.recentBans() }
    }
}

// MARK: - 兑换码

// MARK: - 封禁申诉 (被封用户的申诉列表, 站主/管理员可直接解封)
struct AdminAppealsView: View {
    struct AppealRow: Decodable, Identifiable {
        var username: String?
        var content: String?
        var created_at: String?
        var id: String { (username ?? "") + "|" + (created_at ?? "") }
        var timeText: String { String((created_at ?? "").prefix(16)).replacingOccurrences(of: "T", with: " ") }
    }

    @State private var rows: [AppealRow] = []
    @State private var loaded = false
    @State private var note = ""

    var body: some View {
        List {
            if loaded && rows.isEmpty {
                Text("暂无申诉").foregroundColor(.secondary)
            }
            ForEach(rows) { r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("@" + (r.username ?? "?")).font(.subheadline.weight(.bold))
                        Spacer()
                        Text(r.timeText).font(.caption2).foregroundColor(.secondary)
                    }
                    Text(r.content ?? "").font(.callout)
                    Button("解封该用户") { Task { await unban(r.username ?? "") } }
                        .font(.caption.weight(.bold))
                }
                .padding(.vertical, 2)
            }
            if !note.isEmpty { Text(note).font(.footnote).foregroundColor(.secondary) }
        }
        .navigationTitle("封禁申诉")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        let rows: [AppealRow]? = try? await SB.rpc("list_appeals", params: [
            "p_token": Session.shared.loginToken, "p_limit": 50])
        self.rows = rows ?? []
        loaded = true
    }

    private func unban(_ name: String) async {
        guard !name.isEmpty else { return }
        let (ok, _) = await AdminAPI.exec(action: "unban", target: name, detail: "")
        note = ok ? "已解封 @\(name)" : "解封失败"
        await load()
    }
}

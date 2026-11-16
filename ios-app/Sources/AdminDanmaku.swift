import SwiftUI

/// 弹幕管理 (站主专属): 全站最新弹幕巡检 + 删除
struct AdminDanmakuView: View {
    struct Row: Decodable, Identifiable {
        var id: Int
        var video_id: String?
        var username: String?
        var content: String?
        var created_at: String?
    }

    @EnvironmentObject var session: Session
    @State private var rows: [Row] = []
    @State private var note = ""

    var body: some View {
        List {
            if !note.isEmpty {
                Text(note).font(.caption).foregroundColor(.secondary)
            }
            if rows.isEmpty {
                Text("暂无弹幕").foregroundColor(.secondary)
            }
            ForEach(rows) { r in
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.content ?? "").font(.system(size: 14))
                    Text("@\(r.username ?? "") · \(r.video_id ?? "") · \(String((r.created_at ?? "").prefix(16)))")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .swipeActions {
                    Button("删除", role: .destructive) {
                        Task { await delete(r) }
                    }
                }
            }
        }
        .navigationTitle("弹幕管理")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        let (got, _): ([Row], Int?) = (try? await SB.get("rest/v1/video_danmaku", query: [
            URLQueryItem(name: "select", value: "id,video_id,username,content,created_at"),
            URLQueryItem(name: "order", value: "id.desc"),
            URLQueryItem(name: "limit", value: "80"),
        ])) ?? ([], nil)
        rows = got
    }

    private func delete(_ r: Row) async {
        struct R: Decodable { var ok: Bool?; var message: String? }
        let res: [R] = (try? await SB.rpc("delete_danmaku",
            params: ["p_token": session.loginToken, "p_id": r.id])) ?? []
        if res.first?.ok == true {
            rows.removeAll { $0.id == r.id }
            note = "已删除一条弹幕"
        } else {
            note = res.first?.message ?? "删除失败"
        }
    }
}

import SwiftUI

// 由 AdminContent.swift 拆分 (v5.3: 每个功能一个文件)

struct AdminCommentsView: View {
    @State private var rows: [[String: Any]] = []

    var body: some View {
        List {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("@" + adminStr(r, "username")).font(.subheadline).bold()
                        Text(adminStr(r, "video_id")).font(.caption2).foregroundColor(.secondary)
                        Spacer()
                        Button("删除") {
                            if let id = (r["id"] as? NSNumber)?.intValue { Task { await del(id) } }
                        }
                        .font(.caption).foregroundColor(.red)
                    }
                    Text(adminStr(r, "content")).font(.callout)
                    Text(String(adminStr(r, "created_at").prefix(16))).font(.caption2).foregroundColor(.secondary)
                }
            }
            if rows.isEmpty { Text("暂无评论").foregroundColor(.secondary) }
        }
        .navigationTitle("评论管理")
        .task { await load() }
    }

    private func load() async {
        rows = await AdminAPI.restRows("rest/v1/video_comments", query: [
            URLQueryItem(name: "select", value: "id,video_id,username,content,created_at"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "100"),
        ])
    }

    private func del(_ id: Int) async {
        _ = try? await SB.delete("rest/v1/video_comments", query: [
            URLQueryItem(name: "id", value: "eq.\(id)")])
        await load()
    }
}

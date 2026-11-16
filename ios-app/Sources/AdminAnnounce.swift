import SwiftUI

// 由 AdminContent.swift 拆分 (v5.3: 每个功能一个文件)

struct AdminAnnounceView: View {
    @State private var rows: [[String: Any]] = []
    @State private var title = ""
    @State private var content = ""
    @State private var note = ""

    var body: some View {
        List {
            Section("发布新公告") {
                TextField("标题", text: $title)
                TextField("内容", text: $content)
                Button("发布") { Task { await publish() } }
                    .disabled(title.isEmpty || content.isEmpty)
                if !note.isEmpty { Text(note).font(.caption) }
            }
            Section("全部公告 (\(rows.count))") {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(adminStr(r, "title")).font(.subheadline).bold()
                        Text(adminStr(r, "content")).font(.caption).foregroundColor(.secondary).lineLimit(3)
                        HStack {
                            Text(adminStr(r, "created_at").prefix(10))
                            Text(adminBool(r, "is_active") ? "· 显示中" : "· 已隐藏")
                            Spacer()
                            Button("删除") {
                                if let id = (r["id"] as? NSNumber)?.intValue { Task { await del(id) } }
                            }
                            .font(.caption).foregroundColor(.red)
                        }
                        .font(.caption2).foregroundColor(.secondary)
                    }
                }
                if !rows.isEmpty {
                    Button("清空全部公告", role: .destructive) { Task { await clearAll() } }
                }
            }
        }
        .navigationTitle("公告管理")
        .task { await load() }
    }

    private func load() async {
        rows = await AdminAPI.restRows("rest/v1/announcements", query: [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "100"),
        ])
    }

    private func publish() async {
        let (ok, msg) = await AdminAPI.announcePublish(title: title, content: content)
        note = ok ? "✅ 已发布" : "❌ " + msg
        if ok { title = ""; content = ""; await load() }
    }

    private func del(_ id: Int) async {
        _ = await AdminAPI.announceDelete(id: id)
        await load()
    }

    private func clearAll() async {
        _ = await AdminAPI.announceClear()
        await load()
    }
}

// MARK: - 站内页管理

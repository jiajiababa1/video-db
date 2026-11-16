import SwiftUI

/// 作者管理 (站主专属): 查作者精确作品数/播放量、看他的视频、必要时整作者下架
struct AuthorAdminView: View {
    @EnvironmentObject var session: Session
    @State private var author = ""
    @State private var statsText = ""
    @State private var videos: [VideoItem] = []
    @State private var note = ""
    @State private var confirmDelete = false
    @State private var busy = false

    var body: some View {
        List {
            Section("查询作者") {
                HStack {
                    TextField("作者名", text: $author)
                        .autocorrectionDisabled()
                    Button("查询") { Task { await query() } }
                        .disabled(author.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
                if !statsText.isEmpty {
                    Text(statsText).font(.callout)
                }
                if !note.isEmpty {
                    Text(note).font(.caption).foregroundColor(.secondary)
                }
            }
            if !videos.isEmpty {
                Section("他的视频 (\(videos.count))") {
                    ForEach(videos) { v in
                        VideoRowLink(v: v)
                    }
                }
                Section {
                    Button("删除该作者全部视频", role: .destructive) {
                        confirmDelete = true
                    }
                }
            }
        }
        .navigationTitle("作者管理")
        .confirmationDialog("确定删除「\(author)」的全部视频？此操作不可恢复",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("确认删除", role: .destructive) { Task { await deleteAll() } }
            Button("取消", role: .cancel) {}
        }
    }

    private func query() async {
        busy = true
        let name = author.trimmingCharacters(in: .whitespaces)
        struct R: Decodable { var videos: Int?; var views: Int? }
        let rows: [R] = (try? await SB.rpc("author_stats", params: ["p_author": name])) ?? []
        if let r = rows.first {
            statsText = "\(name)：共 \(r.videos ?? 0) 个视频 · 总播放 \(r.views ?? 0)"
        } else {
            statsText = "没查到这个作者"
        }
        let page = try? await FeedService.fetchPage(playableOnly: false, author: name, page: 1)
        videos = page?.items ?? []
        busy = false
    }

    private func deleteAll() async {
        struct R: Decodable { var deleted: Int? }
        let name = author.trimmingCharacters(in: .whitespaces)
        let rows: [R] = (try? await SB.rpc("admin_delete_videos", params: [
            "p_token": session.loginToken,
            "p_ids": [String](),
            "p_filter": "author",
            "p_value": name,
        ])) ?? []
        let n = rows.first?.deleted ?? 0
        note = "已删除 \(n) 个视频"
        videos = []
        statsText = ""
    }
}

import SwiftUI

struct CommentItem: Codable, Identifiable {
    var id: Int?
    var video_id: String?
    var username: String?
    var content: String?
    var created_at: String?

    var timeText: String {
        guard let c = created_at else { return "" }
        return String(c.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }
}

/// 评论区 (读免登录; 写需登录, 与网站一致)
struct CommentsView: View {
    let video: VideoItem
    @EnvironmentObject var session: Session
    @State private var comments: [CommentItem] = []
    @State private var loaded = false
    @State private var missing = false
    @State private var draft = ""
    @State private var posting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("评论 \(loaded && !missing ? "(\(comments.count))" : "")")
                .font(.system(size: 16, weight: .bold))
            if missing {
                Text("评论区待站主开启")
                    .font(.footnote).foregroundColor(Theme.sub)
            } else if loaded && comments.isEmpty {
                Text("还没有评论, 来抢沙发吧 🛋")
                    .font(.footnote).foregroundColor(Theme.sub)
            }
            ForEach(comments) { c in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("@" + (c.username ?? "?"))
                            .font(.caption.weight(.bold)).foregroundColor(Theme.gold2)
                        Text(c.timeText)
                            .font(.caption2).foregroundColor(Theme.sub)
                        Spacer()
                        if session.isAdmin || (session.username != nil && c.username == session.username) {
                            Button {
                                Task { await delete(c) }
                            } label: {
                                Image(systemName: "trash").font(.caption2).foregroundColor(Theme.sub)
                            }
                        }
                    }
                    Text(c.content ?? "")
                        .font(.system(size: 13.5))
                }
                .padding(.vertical, 6)
                Divider().background(Theme.line)
            }
            if session.isLoggedIn {
                HStack(spacing: 8) {
                    TextField("说点什么…", text: $draft)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Theme.surface2)
                        .cornerRadius(99)
                    Button("发送") {
                        Task { await post() }
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Theme.gold2)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || posting)
                }
            } else {
                Text("登录后可参与评论 (在「我的」里登录)")
                    .font(.caption).foregroundColor(Theme.sub)
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let (rows, _): ([CommentItem], Int?) = try await SB.get(
                "rest/v1/video_comments",
                query: [
                    URLQueryItem(name: "video_id", value: "eq." + video.video_id),
                    URLQueryItem(name: "order", value: "created_at.desc"),
                    URLQueryItem(name: "limit", value: "100"),
                ])
            comments = rows
        } catch {
            missing = true
        }
        loaded = true
    }

    private func post() async {
        guard let user = session.username else { return }
        posting = true
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let _: [CommentItem] = try await SB.post("rest/v1/video_comments",
                body: ["video_id": video.video_id, "username": user, "content": content])
            draft = ""
            await load()
        } catch {}
        posting = false
    }

    private func delete(_ c: CommentItem) async {
        guard let id = c.id else { return }
        try? await SB.delete("rest/v1/video_comments",
            query: [URLQueryItem(name: "id", value: "eq." + String(id))])
        await load()
    }
}

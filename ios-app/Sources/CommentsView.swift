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

    /// 抖音式相对时间: 刚刚 / N分钟前 / N小时前 / N天前 / 日期
    var relativeTime: String {
        guard let c = created_at else { return "" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var d = f.date(from: c)
        if d == nil {
            f.formatOptions = [.withInternetDateTime]
            d = f.date(from: c)
        }
        guard let date = d else { return timeText }
        let s = max(0, Date().timeIntervalSince(date))
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(Int(s / 60))分钟前" }
        if s < 86400 { return "\(Int(s / 3600))小时前" }
        if s < 86400 * 30 { return "\(Int(s / 86400))天前" }
        return String(c.prefix(10))
    }
}

/// 评论抽屉 (刷视频里点「评论」打开, 抖音式底部弹层)
struct CommentsSheet: View {
    let video: VideoItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("评论")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Theme.sub)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider().background(Theme.line)
            CommentsView(video: video, embedded: false)
        }
        .background(Theme.bg.ignoresSafeArea())
    }
}

/// 评论区 (读免登录; 写需登录, 与网站一致)
/// embedded=true: 播放页内嵌 (跟随页面滚动); false: 抽屉模式 (列表独立滚动, 输入框钉底)
struct CommentsView: View {
    let video: VideoItem
    var embedded: Bool = true
    @EnvironmentObject var session: Session
    @State private var comments: [CommentItem] = []
    @State private var loaded = false
    @State private var missing = false
    @State private var draft = ""
    @State private var posting = false

    var body: some View {
        Group {
            if embedded {
                VStack(alignment: .leading, spacing: 10) {
                    Text("评论 \(loaded && !missing ? "(\(comments.count))" : "")")
                        .font(.system(size: 16, weight: .bold))
                    rows
                    composer
                }
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) { rows }
                            .padding(16)
                    }
                    Divider().background(Theme.line)
                    composer
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var rows: some View {
        if missing {
            Text("评论区待站主开启")
                .font(.footnote).foregroundColor(Theme.sub)
        } else if loaded && comments.isEmpty {
            Text("还没有评论, 来抢沙发吧 🛋")
                .font(.footnote).foregroundColor(Theme.sub)
        }
        ForEach(comments) { c in
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().fill(Theme.surface2)
                    Text(String((c.username ?? "?").prefix(1)))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Theme.text)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(c.username ?? "?")
                            .font(.caption.weight(.semibold)).foregroundColor(Theme.sub)
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
                        .font(.system(size: 14))
                    Text(c.relativeTime)
                        .font(.caption2).foregroundColor(Theme.sub)
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var composer: some View {
        if session.isLoggedIn {
            HStack(spacing: 8) {
                TextField("说点什么…", text: $draft)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .glassCapsule()
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

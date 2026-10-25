import SwiftUI

// MARK: - 公告栏 (announcements 表, 与网站横幅同源)
struct Announcement: Codable, Identifiable {
    var id: Int
    var title: String?
    var content: String?
    var is_active: Bool?
    var created_at: String?
}

enum ExtrasAPI {
    static func announcements() async -> [Announcement] {
        let (rows, _): ([Announcement], Int?) = (try? await SB.get("rest/v1/announcements", query: [
            URLQueryItem(name: "is_active", value: "is.true"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "3"),
        ])) ?? ([], nil)
        return rows
    }

    struct SitePage: Codable {
        var slug: String?
        var title: String?
        var content: String?
        var updated_at: String?
    }

    static func sitePage(slug: String) async -> SitePage? {
        let (rows, _): ([SitePage], Int?) = (try? await SB.get("rest/v1/site_pages", query: [
            URLQueryItem(name: "slug", value: "eq." + slug),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "limit", value: "1"),
        ])) ?? ([], nil)
        return rows.first
    }

    /// 作品投稿 (普通用户走 work_requests 待审核; 站主直发 works)
    static func submitWork(title: String, fileUrl: String, coverUrl: String,
                           desc: String, session: Session) async -> String {
        guard session.isLoggedIn, let me = session.username else { return "先登录再投稿" }
        if session.isAdmin {
            do {
                try await SB.insert("rest/v1/works", body: [
                    "title": title, "file_url": fileUrl, "cover_url": coverUrl,
                    "description": desc, "author": me,
                ])
                return "已发布到作品墙 ✓"
            } catch { return "发布失败, 再试一次" }
        }
        do {
            try await SB.insert("rest/v1/work_requests", body: [
                "title": title, "file_url": fileUrl, "cover_url": coverUrl,
                "description": desc, "status": "pending", "submitter": me,
            ])
            return "已提交, 等站主审核 ✓"
        } catch { return "提交失败, 再试一次" }
    }
}

/// 站内页面 (关于 / 联系站主等, 读 site_pages 并纯文本展示)
struct SitePageView: View {
    let slug: String
    let fallbackTitle: String
    @State private var page: ExtrasAPI.SitePage? = nil
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let p = page {
                    Text(p.title ?? fallbackTitle)
                        .font(.system(size: 19, weight: .bold))
                    Text(Self.plainText(p.content ?? ""))
                        .font(.system(size: 14.5))
                        .lineSpacing(6)
                } else if loaded {
                    Text("这个页面还没有内容")
                        .foregroundColor(Theme.sub)
                        .padding(.top, 40)
                } else {
                    ProgressView().tint(Theme.gold).padding(.top, 40)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(fallbackTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            page = await ExtrasAPI.sitePage(slug: slug)
            loaded = true
        }
    }

    /// 粗略去 HTML 标签 (站内页正文以简单排版为主)
    static func plainText(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "<br>", with: "\n")
        s = s.replacingOccurrences(of: "<br/>", with: "\n")
        s = s.replacingOccurrences(of: "</p>", with: "\n\n")
        while let r = s.range(of: "<[^>]+>", options: .regularExpression) {
            s.removeSubrange(r)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 作品投稿表单
struct WorkSubmitView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var fileUrl = ""
    @State private var coverUrl = ""
    @State private var desc = ""
    @State private var note: String? = nil
    @State private var busy = false

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                field("作品标题", text: $title)
                field("文件链接 (视频直链)", text: $fileUrl)
                field("封面链接 (可空)", text: $coverUrl)
                field("简介 (可空)", text: $desc)
                if let n = note {
                    Text(n).font(.footnote).foregroundColor(Theme.gold2)
                }
                Button {
                    Task { await submit() }
                } label: {
                    Text(busy ? "提交中…" : (session.isAdmin ? "直接发布" : "提交审核"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.goldGradient)
                        .foregroundColor(.black)
                        .cornerRadius(12)
                }
                .disabled(busy || title.isEmpty || fileUrl.isEmpty)
                Spacer()
            }
            .padding(16)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("投稿作品")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .autocapitalization(.none)
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(Theme.surface2)
            .cornerRadius(10)
    }

    private func submit() async {
        busy = true
        note = await ExtrasAPI.submitWork(title: title, fileUrl: fileUrl,
                                          coverUrl: coverUrl, desc: desc, session: session)
        busy = false
        if note?.contains("✓") == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismiss() }
        }
    }
}

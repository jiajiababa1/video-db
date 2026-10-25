import SwiftUI

// MARK: - 管理面板 (照搬网站管理面板, 凭登录 token 走同一套 admin RPC)

struct AdminView: View {
    @State private var stats: [(String, String)] = []
    @State private var loadingStats = true

    var body: some View {
        List {
            Section("概览") {
                if loadingStats {
                    HStack { ProgressView(); Text("加载统计中…").foregroundColor(.secondary) }
                }
                ForEach(stats, id: \.0) { s in
                    HStack { Text(s.0); Spacer(); Text(s.1).foregroundColor(.secondary) }
                }
            }
            Section("内容管理") {
                nav("视频管理", "play.rectangle.on.rectangle") { AdminVideosView() }
                nav("公告管理", "megaphone") { AdminAnnounceView() }
                nav("站内页管理", "doc.text") { AdminPagesView() }
                nav("评论管理", "text.bubble") { AdminCommentsView() }
            }
            Section("用户管理") {
                nav("用户列表 / VIP / 封禁", "person.2.badge.gearshape") { AdminUsersView() }
                nav("群发私信", "paperplane") { AdminBroadcastView() }
                nav("私信总览", "envelope.open") { AdminMessagesView() }
                nav("封禁记录", "hand.raised") { AdminBansView() }
            }
            Section("运营") {
                nav("兑换码", "ticket") { AdminCodesView() }
                nav("系统配置", "slider.horizontal.3") { AdminConfigView() }
            }
            Section("爬虫") {
                nav("爬虫控制台 / 作者抓", "spider") { AdminScrapeView() }
            }
            Section("维护") {
                nav("数据维护", "wrench.and.screwdriver") { AdminDataView() }
            }
        }
        .navigationTitle("管理面板")
        .task { await loadStats() }
    }

    private func nav<D: View>(_ title: String, _ icon: String, @ViewBuilder _ dest: () -> D) -> some View {
        NavigationLink { dest() } label: {
            Label(title, systemImage: icon)
        }
    }

    private func loadStats() async {
        async let total = AdminAPI.restCount("rest/v1/videos", query: [URLQueryItem(name: "select", value: "video_id")])
        async let playable = AdminAPI.restCount("rest/v1/videos", query: [
            URLQueryItem(name: "select", value: "video_id"), URLQueryItem(name: "has_mp4", value: "eq.true")])
        async let rescrape = AdminAPI.restCount("rest/v1/videos", query: [
            URLQueryItem(name: "select", value: "video_id"), URLQueryItem(name: "needs_rescrape", value: "eq.true")])
        async let removed = AdminAPI.restCount("rest/v1/videos", query: [
            URLQueryItem(name: "select", value: "video_id"), URLQueryItem(name: "removed", value: "eq.true")])
        async let users = AdminAPI.restCount("rest/v1/user_accounts", query: [URLQueryItem(name: "select", value: "username")])
        async let comments = AdminAPI.restCount("rest/v1/video_comments", query: [URLQueryItem(name: "select", value: "id")])
        async let boards = AdminAPI.restCount("rest/v1/board_groups", query: [URLQueryItem(name: "select", value: "id")])
        let (t, p, r, rm, u, c, b) = await (total, playable, rescrape, removed, users, comments, boards)
        stats = [
            ("视频总数", fmt(t)), ("可播放（有直链）", fmt(p)), ("待重爬", fmt(r)),
            ("已下架", fmt(rm)), ("注册用户", fmt(u)), ("评论总数", fmt(c)), ("板块群", fmt(b)),
        ]
        loadingStats = false
    }

    private func fmt(_ n: Int?) -> String { n.map { "\($0)" } ?? "—" }
}

// MARK: - 通用小工具

func adminStr(_ d: [String: Any], _ key: String) -> String {
    if let s = d[key] as? String { return s }
    if let n = d[key] as? NSNumber { return n.stringValue }
    if let b = d[key] as? Bool { return b ? "true" : "false" }
    return ""
}

func adminBool(_ d: [String: Any], _ key: String) -> Bool {
    if let b = d[key] as? Bool { return b }
    if let n = d[key] as? NSNumber { return n.boolValue }
    if let s = d[key] as? String { return s == "true" || s == "t" }
    return false
}

import SwiftUI

// v2.1 新功能接入层: 真点赞 / 弹幕 / 服务端进度 / 设备管理 / 审计日志 /
// 作者排行榜 / 关注更新流 / 今日新增 / 我赞过的。
// 后端接口已在 Supabase 侧建好 (2026-11-14), 统一走 sessions 表令牌校验。

// MARK: - 真点赞 API

enum LikesAPI {
    struct Status: Decodable { var liked: Bool?; var total: Int? }
    struct Toggle: Decodable { var ok: Bool?; var liked: Bool?; var total: Int? }
    struct Mine: Decodable { var video_id: String? }

    static func status(_ videoId: String) async -> (liked: Bool, total: Int) {
        let rows: [Status]? = try? await SB.rpc("like_status", params: [
            "p_token": Session.shared.loginToken, "p_video_id": videoId])
        if let r = rows?.first { return (r.liked ?? false, r.total ?? 0) }
        return (false, 0)
    }

    static func toggle(_ videoId: String) async -> (liked: Bool, total: Int)? {
        let rows: [Toggle]? = try? await SB.rpc("toggle_like", params: [
            "p_token": Session.shared.loginToken, "p_video_id": videoId])
        guard let r = rows?.first, r.ok == true else { return nil }
        return (r.liked ?? false, r.total ?? 0)
    }

    static func myLikedIds(limit: Int = 100) async -> [String] {
        let rows: [Mine]? = try? await SB.rpc("my_likes", params: [
            "p_token": Session.shared.loginToken, "p_limit": limit])
        return (rows ?? []).compactMap { $0.video_id }
    }
}

// MARK: - 服务端观看进度同步 (网站 ↔ App 续播)

final class ProgressSync {
    static let shared = ProgressSync()
    private var pulled = false
    private var lastWrite: [String: Date] = [:]

    struct Row: Decodable { var video_id: String?; var progress: Double? }

    /// 把服务端进度补进本机片库 (只补本机没有的条目, 本机已有以本机为准)
    func pullIntoLibrary(_ library: Library) {
        guard !pulled, Session.shared.isLoggedIn else { return }
        pulled = true
        Task {
            let rows: [Row]? = try? await SB.rpc("get_progress", params: [
                "p_token": Session.shared.loginToken])
            guard let rows = rows, !rows.isEmpty else { return }
            await MainActor.run {
                var changed = false
                for r in rows {
                    if let id = r.video_id, let p = r.progress, library.progress[id] == nil {
                        library.progress[id] = min(max(p, 0), 1)
                        changed = true
                    }
                }
                if changed { library.persistNow() }
            }
        }
    }

    /// 节流上报 (同一视频 8 秒最多一次); 播放 tick 里调用
    func report(videoId: String, frac: Double) {
        guard Session.shared.isLoggedIn, frac > 0.02, frac < 0.98 else { return }
        let now = Date()
        if let last = lastWrite[videoId], now.timeIntervalSince(last) < 8 { return }
        lastWrite[videoId] = now
        Task {
            struct R: Decodable { var ok: Bool? }
            let _: [R]? = try? await SB.rpc("set_progress", params: [
                "p_token": Session.shared.loginToken, "p_video_id": videoId, "p_progress": frac])
        }
    }
}

// MARK: - 弹幕

struct DanmakuItem: Decodable, Identifiable {
    var id: Int?
    var video_id: String?
    var username: String?
    var content: String?
    var time_offset: Double?
    var created_at: String?
}

/// 弹幕层: 弹幕从其出现时间点起 9 秒内从右向左飘过, 4 条轨道轮转
struct DanmakuOverlay: View {
    let items: [DanmakuItem]
    let currentTime: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(active) { d in
                    Text(d.content ?? "")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.85), radius: 2, x: 0, y: 1)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: xPos(d, width: geo.size.width),
                                y: 4 + CGFloat(lane(d)) * 22)
                }
            }
        }
        .allowsHitTesting(false)
        .clipped()
    }

    private var active: [DanmakuItem] {
        items.filter { d in
            let t = d.time_offset ?? 0
            return currentTime >= t && currentTime - t < 9
        }
    }

    private func xPos(_ d: DanmakuItem, width: CGFloat) -> CGFloat {
        let age = currentTime - (d.time_offset ?? 0)
        return width * CGFloat(1 - age / 9) - 30
    }

    private func lane(_ d: DanmakuItem) -> Int { abs(d.id ?? 0) % 4 }
}

/// 弹幕发送条 (播放页播放器下方)
struct DanmakuBar: View {
    let videoId: String
    let currentTime: Double
    @Binding var items: [DanmakuItem]
    @Binding var enabled: Bool
    @EnvironmentObject var session: Session
    @State private var draft = ""
    @State private var sending = false

    var body: some View {
        HStack(spacing: 8) {
            Button { enabled.toggle() } label: {
                Text("弹")
                    .font(.system(size: 12, weight: .heavy))
                    .frame(width: 30, height: 30)
                    .background(enabled ? Theme.gold : Theme.surface2)
                    .foregroundColor(enabled ? .black : Theme.sub)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            if session.isLoggedIn {
                TextField("发条弹幕…", text: $draft)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .glassCapsule()
                Button("发送") { Task { await send() } }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.gold2)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || sending)
            } else {
                Text("登录后可发弹幕")
                    .font(.caption).foregroundColor(Theme.sub)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        struct R: Decodable { var ok: Bool?; var message: String? }
        let rows: [R]? = try? await SB.rpc("send_danmaku", params: [
            "p_token": Session.shared.loginToken, "p_video_id": videoId,
            "p_content": text, "p_offset": currentTime])
        if rows?.first?.ok == true {
            items.append(DanmakuItem(id: -(items.count + 1), video_id: videoId,
                                     username: session.username, content: text,
                                     time_offset: currentTime, created_at: nil))
            items.sort { ($0.time_offset ?? 0) < ($1.time_offset ?? 0) }
            draft = ""
        }
        sending = false
    }
}

// MARK: - 视频行 (关注流 / 今日新增 / 我赞过的 共用)

struct VideoRowLink: View {
    let v: VideoItem

    var body: some View {
        NavigationLink {
            PlayerView(video: v)
        } label: {
            HStack(spacing: 10) {
                CachedImage(urlString: v.thumbnail_url ?? "")
                    .frame(width: 104, height: 62)
                    .clipped()
                    .cornerRadius(8)
                VStack(alignment: .leading, spacing: 4) {
                    Text(v.displayTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(2)
                        .foregroundColor(Theme.text)
                    if !v.displayAuthor.isEmpty {
                        Text("@" + v.displayAuthor)
                            .font(.caption).foregroundColor(Theme.sub)
                    }
                    if let t = v.viewsText {
                        Text(t + " 观看")
                            .font(.caption2).foregroundColor(Theme.sub)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 通用视频列表页 (关注更新 / 今日新增 共用骨架, 上拉分页由 onAppear 触发)
struct RemoteFeedView: View {
    let navTitle: String
    let emptyText: String
    /// (page) -> 追加在 cols 之后的过滤串 (以 & 开头); nil 表示没有更多过滤条件
    let filterForPage: (Int) -> String

    @State private var items: [VideoItem] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded && items.isEmpty {
                Text(emptyText)
                    .font(.footnote).foregroundColor(Theme.sub)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(items) { v in
                            VideoRowLink(v: v)
                                .padding(.horizontal, 16)
                        }
                        if hasMore {
                            ProgressView()
                                .tint(Theme.gold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .onAppear { Task { await loadMore() } }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !loaded {
                loaded = true
                await loadMore()
            }
        }
    }

    private func loadMore() async {
        let p = page
        let url = SB.base.absoluteString + "/rest/v1/videos?" + FeedService.cols
            + filterForPage(p)
            + "&order=created_at.desc,video_id.desc&limit=24&offset=" + String((p - 1) * 24)
        let (rows, _): ([VideoItem], Int?) = (try? await SB.getRaw(url)) ?? ([], nil)
        items.append(contentsOf: rows)
        hasMore = rows.count >= 24
        page = p + 1
    }
}

/// 把一组值拼成 PostgREST in.(...) 过滤值: 先剔除会破坏语法的字符
func pgInList(_ values: [String]) -> String {
    let bad = CharacterSet(charactersIn: "\"(),&")
    let clean = values
        .map { $0.components(separatedBy: bad).joined() }
        .filter { !$0.isEmpty }
    return "in.(\"" + clean.joined(separator: "\",\"") + "\")"
}

let playableOrFilter = "&or=(has_mp4.eq.true,duration.like.*video.twimg.com*)"

// MARK: - 关注更新流

struct FollowFeedView: View {
    @EnvironmentObject var library: Library

    var body: some View {
        if library.follows.isEmpty {
            VStack(spacing: 10) {
                Text("还没关注任何作者")
                    .font(.system(size: 15, weight: .bold))
                Text("在视频页点「+ 关注」后, 他们的新视频会出现在这里")
                    .font(.footnote).foregroundColor(Theme.sub)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("关注更新")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            RemoteFeedView(navTitle: "关注更新", emptyText: "关注的作者还没有新视频") { _ in
                "&removed=not.is.true&author=" + pgInList(library.follows) + playableOrFilter
            }
        }
    }
}

// MARK: - 今日新增

struct TodayFeedView: View {
    var body: some View {
        RemoteFeedView(navTitle: "今日新增", emptyText: "今天还没有新入库的视频") { _ in
            "&removed=not.is.true&created_at=gte." + Self.todayStartISO + playableOrFilter
        }
    }

    private static var todayStartISO: String {
        let start = Calendar.current.startOfDay(for: Date())
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: start)
    }
}

// MARK: - 我赞过的

struct LikedVideosView: View {
    @EnvironmentObject var session: Session
    @State private var items: [VideoItem] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if !session.isLoggedIn {
                hint("登录后这里会同步你点赞过的视频")
            } else if loaded && items.isEmpty {
                hint("还没点赞过视频\n在刷视频里双击或点爱心就是点赞")
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(items) { v in
                            VideoRowLink(v: v)
                                .padding(.horizontal, 16)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("我赞过的")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !loaded {
                loaded = true
                await load()
            }
        }
    }

    private func hint(_ t: String) -> some View {
        Text(t)
            .multilineTextAlignment(.center)
            .font(.footnote).foregroundColor(Theme.sub)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        let ids = await LikesAPI.myLikedIds()
        guard !ids.isEmpty else { return }
        let url = SB.base.absoluteString + "/rest/v1/videos?" + FeedService.cols
            + "&removed=not.is.true&video_id=" + pgInList(ids) + "&limit=100"
        let (rows, _): ([VideoItem], Int?) = (try? await SB.getRaw(url)) ?? ([], nil)
        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        items = rows.sorted { (order[$0.video_id] ?? 999) < (order[$1.video_id] ?? 999) }
    }
}

// MARK: - 作者排行榜 (服务端缓存榜, 每小时刷新)

struct LeaderboardView: View {
    struct Row: Decodable, Identifiable {
        var name: String?
        var videos_count: Int?
        var total_views: Int?
        var id: String { name ?? "" }
    }

    @State private var rows: [Row] = []
    @State private var loaded = false

    var body: some View {
        List {
            if loaded && rows.isEmpty {
                Text("榜单生成中, 稍后再来看看")
                    .foregroundColor(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                NavigationLink {
                    AuthorView(name: r.name ?? "")
                } label: {
                    HStack(spacing: 12) {
                        Text("\(i + 1)")
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundColor(i < 3 ? Theme.gold2 : Theme.sub)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name ?? "")
                                .font(.system(size: 14.5, weight: .semibold))
                            Text("\(r.videos_count ?? 0) 条视频")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("\(r.total_views ?? 0) 观看")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("作者排行榜")
        .task {
            if !loaded {
                loaded = true
                await load()
            }
        }
    }

    private func load() async {
        let (rs, _): ([Row], Int?) = (try? await SB.get(
            "rest/v1/leaderboard_authors_cache",
            query: [
                URLQueryItem(name: "select", value: "name,videos_count,total_views"),
                URLQueryItem(name: "order", value: "total_views.desc"),
                URLQueryItem(name: "limit", value: "30"),
            ])) ?? ([], nil)
        rows = rs
    }
}

// MARK: - 我的设备

struct DevicesView: View {
    struct Row: Decodable, Identifiable {
        var device_id: String?
        var expires_at: String?
        var is_current: Bool?
        var id: String { device_id ?? UUID().uuidString }
    }

    @State private var rows: [Row] = []
    @State private var loaded = false
    @State private var note = ""

    var body: some View {
        List {
            Section {
                if loaded && rows.isEmpty {
                    Text("没有登录设备记录").foregroundColor(.secondary)
                }
                ForEach(rows) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(deviceName(r.device_id))
                                .font(.system(size: 13.5, weight: .semibold))
                                .lineLimit(1)
                            Text("有效期至 " + String((r.expires_at ?? "").prefix(10)))
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        if r.is_current == true {
                            Text("本机")
                                .font(.caption2.bold()).foregroundColor(.white)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Theme.gold).cornerRadius(99)
                        } else {
                            Button("踢下线") { Task { await kick(r) } }
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.red)
                        }
                    }
                }
            } header: {
                Text("登录设备")
            } footer: {
                Text("踢下线后, 那台设备下次打开 App 就要重新登录。")
            }
            if !note.isEmpty {
                Section { Text(note).font(.footnote) }
            }
        }
        .navigationTitle("我的设备")
        .task {
            if !loaded {
                loaded = true
                await load()
            }
        }
    }

    private func deviceName(_ id: String?) -> String {
        guard let id = id, !id.isEmpty else { return "未知设备" }
        return "设备 " + String(id.prefix(12))
    }

    private func load() async {
        let rs: [Row]? = try? await SB.rpc("my_sessions", params: [
            "p_token": Session.shared.loginToken])
        rows = rs ?? []
    }

    private func kick(_ r: Row) async {
        guard let did = r.device_id else { return }
        struct KR: Decodable { var ok: Bool?; var message: String? }
        let rs: [KR]? = try? await SB.rpc("kick_session", params: [
            "p_token": Session.shared.loginToken, "p_device_id": did])
        note = rs?.first?.ok == true ? "已踢下线" : "操作失败, 请稍后再试"
        await load()
    }
}

// MARK: - 站主审计日志

struct AuditLogView: View {
    struct Row: Decodable, Identifiable {
        var id: Int?
        var admin_user: String?
        var action: String?
        var target: String?
        var detail: String?
        var created_at: String?
    }

    @State private var rows: [Row] = []
    @State private var loaded = false
    @State private var failed = false

    var body: some View {
        List {
            if failed {
                Text("日志暂时读不到 (接口未返回数据)")
                    .foregroundColor(.secondary)
            } else if loaded && rows.isEmpty {
                Text("还没有管理操作记录")
                    .foregroundColor(.secondary)
            }
            ForEach(rows) { r in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(r.admin_user ?? "?")
                            .font(.system(size: 13, weight: .bold))
                        Text(r.action ?? "")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.gold2)
                        Spacer()
                        Text(String((r.created_at ?? "").prefix(16)).replacingOccurrences(of: "T", with: " "))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    if let t = r.target, !t.isEmpty {
                        Text("对象: " + t)
                            .font(.caption).foregroundColor(.secondary)
                    }
                    if let d = r.detail, !d.isEmpty {
                        Text(d)
                            .font(.caption).foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("审计日志")
        .task {
            if !loaded {
                loaded = true
                await load()
            }
        }
    }

    private func load() async {
        do {
            let rs: [Row] = try await SB.rpc("get_audit_log", params: [
                "p_token": Session.shared.loginToken, "p_limit": 100])
            rows = rs
        } catch {
            failed = true
        }
    }
}

import SwiftUI
import UIKit

// v2.1 新功能接入层: 真点赞 / 弹幕 / 服务端进度 / 设备管理 / 审计日志 /
// 作者排行榜 / 关注更新流 / 今日新增 / 我赞过的。
// 后端接口已在 Supabase 侧建好 (2026-11-14), 统一走 sessions 表令牌校验。

// MARK: - 站内页面列表 (动态读 site_pages, 站主建的每个页面都有入口)

struct SitePagesListView: View {
    struct Row: Decodable, Identifiable {
        var slug: String?
        var title: String?
        var id: String { slug ?? "" }
    }

    @State private var rows: [Row] = []
    @State private var loaded = false

    var body: some View {
        List {
            if loaded && rows.isEmpty {
                Text("还没有站内页面\n站主在管理面板「站内页管理」里新建后会出现在这里")
                    .foregroundColor(.secondary)
            }
            ForEach(rows) { r in
                NavigationLink {
                    SitePageView(slug: r.slug ?? "", fallbackTitle: r.title ?? "")
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.title ?? "")
                            .font(.system(size: 14.5, weight: .semibold))
                        Text("/" + (r.slug ?? ""))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("站内页面")
        .task {
            if !loaded {
                loaded = true
                await load()
            }
        }
    }

    private func load() async {
        let (rs, _): ([Row], Int?) = (try? await SB.get(
            "rest/v1/site_pages",
            query: [
                URLQueryItem(name: "select", value: "slug,title"),
                URLQueryItem(name: "order", value: "slug.asc"),
                URLQueryItem(name: "limit", value: "100"),
            ])) ?? ([], nil)
        rows = rs
    }
}

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

/// 弹幕设置 (跟设备走): 字号 / 透明度 / 飘过时长 / 显示区域 / 合并重复。
/// 弹幕条的齿轮按钮打开 DanmakuSettingsView 改这些值, 覆盖层直接读, 立即生效。
enum DanmakuSettings {
    static let fontKey = "vdb_dm_font"        // 11...20, 默认 13
    static let opacityKey = "vdb_dm_opacity"  // 0.3...1, 默认 1
    static let durKey = "vdb_dm_dur"          // 飘过时长秒 5...14, 默认 9 (越小越快)
    static let areaKey = "vdb_dm_area"        // 显示区域 0.35 顶部 / 0.65 半屏 / 1 全屏
    static let mergeKey = "vdb_dm_merge"      // 合并重复弹幕, 默认开
}

struct DanmakuSettingsView: View {
    @AppStorage(DanmakuSettings.fontKey) private var font: Double = 13
    @AppStorage(DanmakuSettings.opacityKey) private var opacity: Double = 1
    @AppStorage(DanmakuSettings.durKey) private var dur: Double = 9
    @AppStorage(DanmakuSettings.areaKey) private var area: Double = 1
    @AppStorage(DanmakuSettings.mergeKey) private var merge: Bool = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("字号") {
                HStack {
                    Slider(value: $font, in: 11...20, step: 1)
                    Text("\(Int(font))").frame(width: 30).foregroundColor(.secondary)
                }
            }
            Section("透明度") {
                HStack {
                    Slider(value: $opacity, in: 0.3...1, step: 0.05)
                    Text("\(Int(opacity * 100))%").frame(width: 44).foregroundColor(.secondary)
                }
            }
            Section("飘过时长 (越短越快)") {
                HStack {
                    Slider(value: $dur, in: 5...14, step: 0.5)
                    Text(String(format: "%.1f 秒", dur)).frame(width: 52).foregroundColor(.secondary)
                }
            }
            Section("显示区域") {
                Picker("显示区域", selection: $area) {
                    Text("顶部").tag(0.35)
                    Text("半屏").tag(0.65)
                    Text("全屏").tag(1.0)
                }
                .pickerStyle(.segmented)
            }
            Section {
                Toggle("合并重复弹幕", isOn: $merge)
            } footer: {
                Text("同一时间刷屏的相同弹幕会合成一条并标出次数，如「前方高能 ×12」。设置只影响显示，立即生效。")
            }
        }
        .navigationTitle("弹幕设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
    }
}

/// 弹幕预处理结果: 合并后的文本 + 出现时间 + 估算宽度 (轨道分配用)
private struct DanmakuPrepared {
    var id: Int
    var base: String
    var count: Int
    var spawn: Double
    var estWidth: CGFloat
    var text: String { count > 1 ? base + " ×\(count)" : base }
}

/// 轨道分配缓存 (引用类型, 避免在 body 里改 @State 值)
private final class DanmakuLaneCache {
    var key: String = ""
    var lanes: [Int: Int] = [:]
}

/// 弹幕层 (v4.9 重做): 轨道分配带碰撞检测 —— 每条弹幕占一条轨道, 按估算宽度算出它
/// 完全进入屏幕的时间, 下一条同轨道弹幕必须等它进完才发, 不再叠成一团
/// (借鉴 B 站开源弹幕引擎 DanmakuFlameMaster 的轨道算法)。
/// 丝滑做法不变: TimelineView 按帧渲染, 以播放器 tick 为锚点按墙钟外推视频时间。
struct DanmakuOverlay: View {
    let items: [DanmakuItem]
    let currentTime: Double
    var playing: Bool = true

    @AppStorage(DanmakuSettings.fontKey) private var fontSize: Double = 13
    @AppStorage(DanmakuSettings.opacityKey) private var dmOpacity: Double = 1
    @AppStorage(DanmakuSettings.durKey) private var duration: Double = 9
    @AppStorage(DanmakuSettings.areaKey) private var area: Double = 1
    @AppStorage(DanmakuSettings.mergeKey) private var merge: Bool = true

    @State private var anchorVideo: Double = 0
    @State private var anchorWall: Date = Date()
    @State private var cache = DanmakuLaneCache()

    private var laneHeight: CGFloat { CGFloat(fontSize) + 9 }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing)) { ctx in
            let vt = videoTime(ctx.date)
            GeometryReader { geo in
                let maxLanes = max(1, Int(geo.size.height * CGFloat(area) / laneHeight))
                let prep = prepared()
                let lanes = lanesFor(prep, width: geo.size.width, maxLanes: maxLanes)
                ZStack(alignment: .topLeading) {
                    ForEach(activePrep(prep, at: vt), id: \.id) { p in
                        Text(p.text)
                            .font(.system(size: CGFloat(fontSize), weight: .semibold))
                            .foregroundColor(.white)
                            .opacity(dmOpacity)
                            .shadow(color: .black.opacity(0.85), radius: 2, x: 0, y: 1)
                            .lineLimit(1)
                            .fixedSize()
                            .offset(x: xPos(p, width: geo.size.width, vt: vt),
                                    y: 4 + CGFloat(lanes[p.id] ?? 0) * laneHeight)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .clipped()
        .onAppear { anchorVideo = currentTime; anchorWall = Date() }
        .onChange(of: currentTime) { t in
            anchorVideo = t
            anchorWall = Date()
        }
        .onChange(of: playing) { _ in
            anchorVideo = currentTime
            anchorWall = Date()
        }
    }

    private func videoTime(_ now: Date) -> Double {
        if !playing { return anchorVideo }
        return anchorVideo + now.timeIntervalSince(anchorWall)
    }

    /// 合并重复: 3 秒内出现的相同弹幕合成一条 (计数), 再按时间排序输出
    private func prepared() -> [DanmakuPrepared] {
        let sorted = items.sorted { ($0.time_offset ?? 0) < ($1.time_offset ?? 0) }
        var out: [DanmakuPrepared] = []
        for d in sorted {
            let t = d.time_offset ?? 0
            let c = (d.content ?? "").trimmingCharacters(in: .whitespaces)
            if c.isEmpty { continue }
            if merge, let last = out.last, last.base == c, t - last.spawn <= 3 {
                out[out.count - 1].count += 1
                continue
            }
            let w = CGFloat(c.count) * CGFloat(fontSize) * 0.98 + 24
            out.append(DanmakuPrepared(id: d.id ?? Int(t * 1000) + out.count,
                                       base: c, count: 1, spawn: t, estWidth: w))
        }
        return out
    }

    /// 轨道分配: 同轨道内, 下一条的出现时间必须 ≥ 上一条「完全进入屏幕」的时间;
    /// 全部轨道都忙时选最早空出的那条 (重叠最小)。结果按输入签名缓存。
    private func lanesFor(_ prep: [DanmakuPrepared], width: CGFloat, maxLanes: Int) -> [Int: Int] {
        let key = "\(prep.count)|\(prep.first?.id ?? 0)|\(prep.last?.id ?? 0)|\(Int(width))|\(maxLanes)|\(fontSize)|\(duration)|\(merge)"
        if cache.key == key { return cache.lanes }
        var freeAt = [Double](repeating: 0, count: max(1, maxLanes))
        var map: [Int: Int] = [:]
        for p in prep {
            let entry = duration * Double(p.estWidth) / Double(max(1, width + p.estWidth))
            var lane = -1
            for i in 0..<freeAt.count where freeAt[i] <= p.spawn { lane = i; break }
            if lane < 0 {
                lane = freeAt.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            }
            map[p.id] = lane
            freeAt[lane] = p.spawn + entry
        }
        cache.key = key
        cache.lanes = map
        return map
    }

    private func activePrep(_ prep: [DanmakuPrepared], at vt: Double) -> [DanmakuPrepared] {
        prep.filter { vt >= $0.spawn && vt - $0.spawn < duration }
    }

    private func xPos(_ p: DanmakuPrepared, width: CGFloat, vt: Double) -> CGFloat {
        let age = vt - p.spawn
        return width - (width + p.estWidth) * CGFloat(age / duration)
    }
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
    @State private var showManage = false
    @State private var showSettings = false

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
            if session.isBanned {
                Text("账号已被封禁，无法发弹幕")
                    .font(.caption).foregroundColor(.red)
                Spacer()
            } else if session.isLoggedIn {
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
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.sub)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            if !items.isEmpty {
                Button { showManage = true } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.sub)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .sheet(isPresented: $showManage) {
            NavigationView {
                DanmakuListView(items: $items)
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationView {
                DanmakuSettingsView()
            }
        }
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

/// 弹幕管理列表: 本人可删自己的, 管理员/站主可删任何人的 (服务端 delete_danmaku 验权)
struct DanmakuListView: View {
    @Binding var items: [DanmakuItem]
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if items.isEmpty {
                Text("这个视频还没有弹幕")
                    .foregroundColor(.secondary)
            }
            ForEach(items) { d in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.content ?? "")
                            .font(.system(size: 14))
                        Text("\(d.username ?? "?") · \(timeText(d.time_offset ?? 0))")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    if canDelete(d) {
                        Button {
                            Task { await delete(d) }
                        } label: {
                            Image(systemName: "trash").foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = d.content ?? ""
                    } label: {
                        Label("复制弹幕", systemImage: "doc.on.doc")
                    }
                    Button {
                        UIPasteboard.general.string = "\(d.username ?? "") \(d.content ?? "")"
                    } label: {
                        Label("复制作者和弹幕", systemImage: "person.crop.square")
                    }
                }
            }
        }
        .navigationTitle("弹幕管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
    }

    private func canDelete(_ d: DanmakuItem) -> Bool {
        guard session.isLoggedIn else { return false }
        return session.isAdmin || session.isOwner || d.username == session.username
    }

    private func timeText(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func delete(_ d: DanmakuItem) async {
        guard let id = d.id else { return }
        if id < 0 {
            // 本地刚发、还没回库的弹幕: 直接从列表拿掉即可
            items.removeAll { $0.id == id }
            return
        }
        struct R: Decodable { var ok: Bool?; var message: String? }
        let rows: [R]? = try? await SB.rpc("delete_danmaku", params: [
            "p_token": session.loginToken, "p_id": id])
        if rows?.first?.ok == true {
            items.removeAll { $0.id == id }
        }
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

// MARK: - 关注分组

/// 关注分组 (跟账号走, 存 UserDefaults 的本账号键, 不进 Library 的 Persist 结构):
/// order = 分组名顺序, map = 作者名 → 分组名 (不在 map 里 = 未分组)
enum FollowGroups {
    struct Store: Codable {
        var order: [String] = []
        var map: [String: String] = [:]
    }

    private static var key: String { "vdb_follow_groups_" + (Session.shared.username ?? "anon") }

    static func load() -> Store {
        guard let raw = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(Store.self, from: raw) else { return Store() }
        return s
    }

    static func save(_ s: Store) {
        if let raw = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(raw, forKey: key)
        }
    }
}

// MARK: - 关注更新流

struct FollowFeedView: View {
    @EnvironmentObject var library: Library
    @State private var selGroup: String? = nil
    @State private var groups = FollowGroups.load()

    private var groupNames: [String] {
        groups.order.filter { g in library.follows.contains { groups.map[$0] == g } }
    }

    private var shownFollows: [String] {
        guard let g = selGroup else { return library.follows }
        return library.follows.filter { groups.map[$0] == g }
    }

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
            VStack(spacing: 0) {
                if !groupNames.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            groupChip("全部", selGroup == nil) { selGroup = nil }
                            ForEach(groupNames, id: \.self) { g in
                                groupChip(g, selGroup == g) { selGroup = g }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .background(Theme.bg)
                }
                RemoteFeedView(navTitle: "关注更新", emptyText: "关注的作者还没有新视频") { _ in
                    "&removed=not.is.true&author=" + pgInList(shownFollows) + playableOrFilter
                }
                .id(selGroup ?? "__all")
            }
            .background(Theme.bg.ignoresSafeArea())
            .onAppear { groups = FollowGroups.load() }
        }
    }

    private func groupChip(_ text: String, _ active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(active ? Theme.gold : Theme.surface2)
                .foregroundColor(active ? .black : Theme.text)
                .cornerRadius(99)
        }
        .buttonStyle(.plain)
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


// MARK: - 标题纠正 (v5.1 标题党治理, 学 DeArrow): 提名更准确的标题, 投票满 5 票自动生效, 站主可直接通过/驳回
struct TitleSuggestion: Decodable, Identifiable {
    var id: FlexInt?
    var video_id: String?
    var current_title: String?
    var suggested_title: String?
    var username: String?
    var votes: FlexInt?
    var my_voted: Bool?
    var created_at: String?
    var sid: Int { id?.value ?? 0 }
    var voteCount: Int { votes?.value ?? 0 }
}

enum TitleAPI {
    struct Res: Decodable { var ok: Bool?; var message: String?; var votes: FlexInt? }
    private static var token: String { Session.shared.loginToken ?? "" }

    static func suggest(videoId: String, title: String) async -> String {
        let rows: [Res] = (try? await SB.rpc("suggest_title", params: ["p_token": token, "p_video_id": videoId, "p_title": title])) ?? []
        return rows.first?.message ?? "提交失败"
    }
    static func list() async -> [TitleSuggestion] {
        let rows: [TitleSuggestion] = (try? await SB.rpc("list_title_suggestions", params: ["p_token": token, "p_limit": 50])) ?? []
        return rows
    }
    static func vote(_ id: Int) async -> String {
        let rows: [Res] = (try? await SB.rpc("vote_title", params: ["p_token": token, "p_suggestion_id": id])) ?? []
        return rows.first?.message ?? "投票失败"
    }
    static func moderate(_ id: Int, action: String) async -> String {
        let rows: [Res] = (try? await SB.rpc("moderate_title", params: ["p_token": token, "p_id": id, "p_action": action])) ?? []
        return rows.first?.message ?? "操作失败"
    }
}

/// 标题纠正列表: 待投票的提名, 谁都能投票; 满 5 票自动生效
struct TitleFixView: View {
    @EnvironmentObject var session: Session
    @State private var items: [TitleSuggestion] = []
    @State private var note = ""
    @State private var navVideo: VideoItem? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("遇到标题党就在播放页点「纠正标题」提名一个准确的标题，大家投票，满 5 票自动换上。站主可直接通过或驳回。")
                    .font(.caption).foregroundColor(Theme.sub)
                if !note.isEmpty {
                    Text(note).font(.caption).foregroundColor(Theme.gold2)
                }
                if items.isEmpty {
                    Text("暂无待纠正的标题")
                        .foregroundColor(Theme.sub)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                }
                ForEach(items) { s in
                    row(s)
                }
            }
            .padding(14)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("标题纠正")
        .navigationBarTitleDisplayMode(.inline)
        .background(
            NavigationLink(isActive: Binding(get: { navVideo != nil },
                                             set: { if !$0 { navVideo = nil } })) {
                if let v = navVideo { PlayerView(video: v) }
            } label: { EmptyView() }
                .hidden()
        )
        .task { items = await TitleAPI.list() }
    }

    private func row(_ s: TitleSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("现标题：" + (s.current_title ?? "（无标题）"))
                .font(.system(size: 12.5)).foregroundColor(Theme.sub).lineLimit(2)
            Text("提名：" + (s.suggested_title ?? ""))
                .font(.system(size: 14, weight: .semibold)).lineLimit(2)
            HStack(spacing: 8) {
                Text("@" + (s.username ?? "") + " 提名")
                    .font(.caption2).foregroundColor(Theme.sub)
                Spacer()
                Button {
                    Task {
                        note = await TitleAPI.vote(s.sid)
                        items = await TitleAPI.list()
                    }
                } label: {
                    Label("\(s.voteCount)/5", systemImage: (s.my_voted ?? false) ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(.system(size: 12.5, weight: .bold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background((s.my_voted ?? false) ? Theme.gold : Theme.surface2)
                        .foregroundColor((s.my_voted ?? false) ? .black : Theme.text)
                        .cornerRadius(99)
                }
                .buttonStyle(.plain)
                Button("看视频") {
                    Task {
                        if let vid = s.video_id,
                           let v = (await FeedService.fetchByIds([vid])).first {
                            navVideo = v
                        }
                    }
                }
                .font(.system(size: 12.5, weight: .semibold)).foregroundColor(Theme.gold2)
            }
            if session.isAdmin || session.isOwner {
                HStack(spacing: 10) {
                    Button("通过（立即生效）") {
                        Task {
                            note = await TitleAPI.moderate(s.sid, action: "apply")
                            items = await TitleAPI.list()
                        }
                    }
                    .font(.system(size: 12.5, weight: .bold)).foregroundColor(.green)
                    Button("驳回", role: .destructive) {
                        Task {
                            note = await TitleAPI.moderate(s.sid, action: "reject")
                            items = await TitleAPI.list()
                        }
                    }
                    .font(.system(size: 12.5)).foregroundColor(.red.opacity(0.85))
                    Spacer()
                }
            }
        }
        .padding(12)
        .glassPanel(14)
    }
}

/// 提名新标题 (播放页「纠正标题」打开)
struct TitleSuggestView: View {
    let video: VideoItem
    @Environment(\.dismiss) private var dismiss
    @State private var newTitle = ""
    @State private var note = ""
    @State private var done = false

    var body: some View {
        Form {
            Section(header: Text("现在的标题")) {
                Text(video.displayTitle).font(.system(size: 14))
            }
            Section(header: Text("提名一个准确的标题（4~60 字）"),
                    footer: Text("提交后进入投票，满 5 票自动换上；乱提名站主会驳回。")) {
                TextField("新标题", text: $newTitle)
                    .autocorrectionDisabled(true)
            }
            if !note.isEmpty {
                Section { Text(note).foregroundColor(Theme.gold2) }
            }
            Section {
                Button(done ? "已提交 ✓" : "提交提名") {
                    Task {
                        let t = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        note = await TitleAPI.suggest(videoId: video.video_id, title: t)
                        if note.contains("已提交") { done = true }
                    }
                }
                .disabled(done || newTitle.trimmingCharacters(in: .whitespaces).count < 4)
                Button("关闭") { dismiss() }
            }
        }
        .navigationTitle("纠正标题")
        .navigationBarTitleDisplayMode(.inline)
    }
}

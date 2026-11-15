import SwiftUI
import UIKit

/// 用户公开资料 (user_profiles 表): 昵称/头像/封面/简介, 个人主页用
struct UserProfile: Codable {
    var username: String
    var nickname: String?
    var avatar_url: String?
    var cover_url: String?
    var bio: String?
    var updated_at: String?

    var displayName: String {
        if let n = nickname, !n.isEmpty { return n }
        return username
    }
}

enum ProfileAPI {
    static func fetch(_ username: String) async -> UserProfile? {
        let (rows, _): ([UserProfile], Int?) = (try? await SB.get("rest/v1/user_profiles", query: [
            URLQueryItem(name: "username", value: "eq." + username),
            URLQueryItem(name: "limit", value: "1"),
        ])) ?? ([], nil)
        return rows.first
    }

    static func save(nickname: String, avatar: String, cover: String, bio: String) async -> Bool {
        struct R: Decodable { var ok: Bool? }
        let rows: [R]? = try? await SB.rpc("set_my_profile", params: [
            "p_token": Session.shared.loginToken,
            "p_nickname": nickname, "p_avatar_url": avatar,
            "p_cover_url": cover, "p_bio": bio])
        return rows?.first?.ok == true
    }

    /// 我收到的点赞总数 (主页「获赞」)
    static func receivedLikes() async -> Int {
        let n: Int? = try? await SB.rpc("my_received_like_count", params: [
            "p_token": Session.shared.loginToken])
        return n ?? 0
    }

    /// 我的数字 ID (user_accounts.id)
    static func myId(_ username: String) async -> Int? {
        struct R: Decodable { var id: Int? }
        let (rows, _): ([R], Int?) = (try? await SB.get("rest/v1/user_accounts", query: [
            URLQueryItem(name: "select", value: "id"),
            URLQueryItem(name: "username", value: "eq." + username),
            URLQueryItem(name: "limit", value: "1"),
        ])) ?? ([], nil)
        return rows.first?.id ?? nil
    }
}

extension WorkItem {
    /// 作品 → 通用 VideoItem: id 用 work:<id>, file_url 按站内约定存进 duration 直链播放
    var asVideoItem: VideoItem {
        VideoItem(video_id: "work:" + String(id), title: title, author: author,
                  thumbnail_url: cover_url, duration: file_url, source_section: "work",
                  views: nil, has_mp4: true, needs_rescrape: nil, video_url: nil,
                  vote_up: nil, vote_down: nil, created_at: created_at,
                  monsnode_video_id: nil, source_page: nil, playable: true, vip_early: nil)
    }
}

/// 图片缓存 (caches/imgcache) 的大小与清理
enum CacheTool {
    static var imgDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("imgcache")
    }

    static func sizeBytes() -> Int64 {
        guard let files = try? FileManager.default.subpathsOfDirectory(atPath: imgDir.path) else { return 0 }
        var total: Int64 = 0
        for f in files {
            let p = imgDir.appendingPathComponent(f).path
            if let attrs = try? FileManager.default.attributesOfItem(atPath: p),
               let s = attrs[.size] as? Int64 {
                total += s
            }
        }
        return total
    }

    static func sizeText() -> String {
        ByteCountFormatter.string(fromByteCount: sizeBytes(), countStyle: .file)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: imgDir)
        URLCache.shared.removeAllCachedResponses()
    }
}

// MARK: - 个人主页 (抖音式)

struct ProfileHomeView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var library: Library
    @State private var profile: UserProfile? = nil
    @State private var myWorks: [WorkItem] = []
    @State private var likedVideos: [VideoItem] = []
    @State private var extraSnaps: [String: VideoItem] = [:]
    @State private var likeCount = 0
    @State private var friendCount = 0
    @State private var myId: Int? = nil
    @State private var seg = 0
    @State private var showDrawer = false
    @State private var showAppeal = false
    @State private var cacheSizeText = ""
    @Environment(\.vdbTabActive) private var tabActive
    @State private var showEdit = false
    @State private var playItem: VideoItem? = nil

    private var me: String { session.username ?? "" }

    private var favItems: [VideoItem] {
        library.favorites.compactMap { library.snapshots[$0] ?? extraSnaps[$0] }
    }
    private var histItems: [VideoItem] {
        library.history.prefix(60).compactMap { library.snapshots[$0] ?? extraSnaps[$0] }
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            if session.isLoggedIn {
                content
            } else {
                loginPrompt
            }
            // 抽屉常驻不卸载, 只靠位移开/关: 卸载会连带销毁抽屉里 NavigationLink
            // 已推出的页面 —— 先是"点了没反应", 改延迟关闭后又变成"点进去自动退出"
            drawerOverlay
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarHidden(true)
        .task { await load() }
        .onChange(of: tabActive) { active in
            // 页面常驻不重建: 切回「我的」时刷新, 刚点的赞/改的资料要立刻能看到
            if active { Task { await load() } }
        }
        .onChange(of: session.accountGeneration) { _ in
            // 换账号后按新账号重拉 (点赞/资料/作品都是每人一份)
            Task { await load() }
        }
        .onChange(of: showDrawer) { open in
            // 缓存大小改在打开时算好放状态里, 不在抽屉构建时同步遍历目录 (那会让三条杠点了半天才动)
            if open { cacheSizeText = CacheTool.sizeText() }
        }
        .sheet(isPresented: $showEdit) {
            NavigationView {
                ProfileEditView(profile: profile) { Task { await load() } }
            }
        }
        .sheet(isPresented: $showAppeal) {
            NavigationView {
                AppealView()
            }
        }
        .sheet(item: $playItem) { v in
            NavigationView { PlayerView(video: v) }
        }
    }

    private var loginPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle").font(.system(size: 52)).foregroundColor(Theme.sub)
            Text("登录后有你的个人主页").foregroundColor(Theme.sub)
            NavigationLink { AuthView() } label: {
                Text("去登录").font(.system(size: 15, weight: .bold))
                    .padding(.horizontal, 26).padding(.vertical, 10)
                    .background(Theme.goldGradient).foregroundColor(.white)
                    .cornerRadius(99)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 0) {
                if session.isBanned {
                    bannedCard
                }
                header
                Picker("主页", selection: $seg) {
                    Text("发布").tag(0)
                    Text("喜欢").tag(1)
                    Text("收藏").tag(2)
                    Text("历史").tag(3)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                segmentContent
                    .padding(.horizontal, 10)
                    .padding(.bottom, 20)
            }
        }
    }

    // MARK: 头部: 封面 + 头像 + 昵称/ID + 数据行 + 编辑主页

    /// 封禁卡 (主页顶部, 封禁时显示): 说明禁言范围 + 申诉入口
    private var bannedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundColor(.red)
                Text("你的账号已被封禁")
                    .font(.system(size: 15, weight: .bold)).foregroundColor(.red)
            }
            Text("封禁期间不能评论、发弹幕、发私信或发布任何内容。可以向站主申诉（每小时限一条）。")
                .font(.caption).foregroundColor(Theme.sub)
            Button {
                showAppeal = true
            } label: {
                Text("联系站主申诉")
                    .font(.system(size: 13.5, weight: .bold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .glassCapsule()
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.red.opacity(0.12))
        .cornerRadius(14)
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private var header: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                if let cover = profile?.cover_url, !cover.isEmpty {
                    CachedImage(urlString: cover)
                        .frame(height: 148)
                        .frame(maxWidth: .infinity)
                        .clipped()
                } else {
                    LinearGradient(colors: [Color(red: 0.16, green: 0.13, blue: 0.22),
                                            Color(red: 0.05, green: 0.05, blue: 0.09)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(height: 148)
                }
                Button { withAnimation(.easeOut(duration: 0.22)) { showDrawer = true } } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .glassCircle()
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
                .padding(.trailing, 14)
            }
            HStack(alignment: .center, spacing: 12) {
                avatarView(size: 68)
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile?.displayName ?? me)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                    Text("@" + me + (myId != nil ? " · ID \(myId!)" : ""))
                        .font(.caption)
                        .foregroundColor(Theme.sub)
                    if session.isOwner {
                        Text("站主")
                            .font(.system(size: 10, weight: .heavy))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.goldGradient)
                            .foregroundColor(.white)
                            .cornerRadius(4)
                    } else if session.isAdmin {
                        Text("管理员")
                            .font(.system(size: 10, weight: .heavy))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.surface2)
                            .foregroundColor(Theme.gold2)
                            .cornerRadius(4)
                    }
                    if session.isBanned {
                        // 名字下面一行小字 (用户点名要的封禁标记)
                        Text("被封禁用户")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.red)
                    }
                }
                Spacer()
                Button { showEdit = true } label: {
                    Text("编辑主页")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .glassCapsule()
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            if let bio = profile?.bio, !bio.isEmpty {
                Text(bio)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }
            HStack(spacing: 0) {
                statItem(value: likeCount, label: "获赞")
                statItem(value: friendCount, label: "互关")
                statItem(value: myWorks.count, label: "发布")
            }
            .padding(.top, 12)
        }
    }

    private func statItem(value: Int, label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(Theme.text)
            Text(label)
                .font(.caption)
                .foregroundColor(Theme.sub)
        }
        .frame(maxWidth: .infinity)
    }

    private func avatarView(size: CGFloat) -> some View {
        Group {
            if let a = profile?.avatar_url, !a.isEmpty {
                CachedImage(urlString: a)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                ZStack {
                    Circle().fill(Theme.goldGradient)
                    Text(String(me.prefix(1)).uppercased())
                        .font(.system(size: size * 0.42, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: size, height: size)
            }
        }
        .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
    }

    // MARK: 分段内容

    @ViewBuilder
    private var segmentContent: some View {
        switch seg {
        case 1:
            videoGrid(likedVideos, empty: "还没有赞过的视频")
        case 2:
            videoGrid(favItems, empty: "还没有收藏")
        case 3:
            videoGrid(histItems, empty: "还没有观看历史")
        default:
            worksGrid
        }
    }

    private var worksGrid: some View {
        Group {
            if myWorks.isEmpty {
                VStack(spacing: 10) {
                    Text("还没有发布过作品")
                        .foregroundColor(Theme.sub)
                        .padding(.top, 26)
                    NavigationLink { WorkSubmitView() } label: {
                        Text("去发布")
                            .font(.system(size: 14, weight: .bold))
                            .padding(.horizontal, 22).padding(.vertical, 9)
                            .background(Theme.goldGradient).foregroundColor(.white)
                            .cornerRadius(99)
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 2),
                                    GridItem(.flexible(), spacing: 2),
                                    GridItem(.flexible(), spacing: 2)], spacing: 2) {
                    ForEach(myWorks) { w in
                        Button { playItem = w.asVideoItem } label: {
                            ZStack(alignment: .bottomLeading) {
                                CachedImage(urlString: w.cover_url ?? "")
                                    .aspectRatio(3 / 4, contentMode: .fill)
                                    .frame(maxWidth: .infinity)
                                    .clipped()
                                    .background(Color.black)
                                Text(w.title ?? "")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .padding(4)
                                    .shadow(radius: 3)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func videoGrid(_ items: [VideoItem], empty: String) -> some View {
        Group {
            if items.isEmpty {
                Text(empty)
                    .foregroundColor(Theme.sub)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 26)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 12) {
                    ForEach(items) { v in
                        NavigationLink { PlayerView(video: v) } label: {
                            VideoCard(video: v)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: 右侧抽屉 (仿抖音个人页侧栏)

    private var drawerOverlay: some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(showDrawer ? 0.45 : 0)
                .ignoresSafeArea()
                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showDrawer = false } }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        NavigationLink { SettingsView() } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "gearshape")
                                Text("设置")
                            }
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundColor(Theme.text)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .glassCapsule()
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded {
                            // 只收起 (位移), 不卸载: 跳转的页面不会被带走
                            showDrawer = false
                        })
                        Spacer()
                        Button { withAnimation(.easeOut(duration: 0.2)) { showDrawer = false } } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Theme.sub)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.bottom, 6)
                    drawerGroup([
                        .link(icon: "clock", title: "观看历史", dest: AnyView(LibraryView())),
                        .link(icon: "text.bubble", title: "我的评论", dest: AnyView(InboxView(initialSeg: 2))),
                        .link(icon: "arrow.down.circle", title: "离线缓存", dest: AnyView(DownloadsView())),
                        .link(icon: "bookmark", title: "稍后再看", dest: AnyView(LibraryView())),
                    ])
                    drawerGroup([
                        .link(icon: "lightbulb", title: "创作者中心", dest: AnyView(CreatorCenterView())),
                        .link(icon: "headphones", title: "联系站主", dest: AnyView(ChatView(peer: "kuo"))),
                        .link(icon: "ticket", title: "兑换 VIP", dest: AnyView(RedeemView())),
                        .link(icon: "iphone", title: "我的设备", dest: AnyView(DevicesView())),
                        .link(icon: "doc.text", title: "站内页面", dest: AnyView(SitePagesListView())),
                    ])
                    if session.isAdmin || session.isOwner {
                        drawerGroup([
                            .link(icon: "crown", title: "站主功能", dest: AnyView(AdminView())),
                        ])
                    }
                    drawerGroup([
                        .action(icon: "trash", title: "清理缓存", note: cacheSizeText.isEmpty ? nil : cacheSizeText) {
                            CacheTool.clear()
                            cacheSizeText = CacheTool.sizeText()
                        },
                        .link(icon: "arrow.left.arrow.right", title: "切换账号", dest: AnyView(AccountSwitcherView())),
                    ])
                    Text("2048 影院 · 原生版 v4.6")
                        .font(.caption2)
                        .foregroundColor(Theme.sub)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 16)
                }
                .padding(14)
            }
            .frame(width: 292)
            .frame(maxHeight: .infinity)
            .background(Theme.surface)
            .offset(x: showDrawer ? 0 : 300)
        }
        .animation(.easeOut(duration: 0.22), value: showDrawer)
        .allowsHitTesting(showDrawer)
        .zIndex(5)
    }

    private enum DrawerItem {
        case link(icon: String, title: String, dest: AnyView)
        case action(icon: String, title: String, note: String?, run: () -> Void)
    }

    @ViewBuilder
    private func drawerGroup(_ items: [DrawerItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                switch item {
                case let .link(icon, title, dest):
                    NavigationLink { dest } label: {
                        drawerRow(icon: icon, title: title, note: nil)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded {
                        // 只收起 (位移), 不卸载: 跳转的页面不会被带走
                        showDrawer = false
                    })
                case let .action(icon, title, note, run):
                    Button {
                        run()
                        withAnimation(.easeOut(duration: 0.2)) { showDrawer = false }
                    } label: {
                        drawerRow(icon: icon, title: title, note: note)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 6)
        .glassPanel(16)
        .padding(.top, 12)
    }

    private func drawerRow(icon: String, title: String, note: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(Theme.text)
                .frame(width: 24)
            Text(title)
                .font(.system(size: 15))
                .foregroundColor(Theme.text)
            Spacer()
            if let note = note {
                Text(note).font(.caption).foregroundColor(Theme.sub)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.sub)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    // MARK: 数据

    private func load() async {
        guard session.isLoggedIn, !me.isEmpty else { return }
        profile = await ProfileAPI.fetch(me)
        likeCount = await ProfileAPI.receivedLikes()
        myId = await ProfileAPI.myId(me)
        let rows = await SocialAPI.myFriendRows(me: me)
        friendCount = rows.filter { $0.status == "accepted" }.count
        let allWorks = await SocialAPI.works()
        myWorks = allWorks.filter { $0.author == me }
        let ids = await LikesAPI.myLikedIds()
        var vids = await FeedService.fetchByIds(ids.filter { !$0.hasPrefix("work:") })
        let workIds = Set(ids.filter { $0.hasPrefix("work:") })
        if !workIds.isEmpty {
            vids += allWorks.map { $0.asVideoItem }.filter { workIds.contains($0.video_id) }
        }
        likedVideos = vids
        let want = Array(Set(Array(library.favorites.prefix(40)) + Array(library.history.prefix(40))))
        let missing = want.filter { library.snapshots[$0] == nil }
        if !missing.isEmpty {
            let fetched = await FeedService.fetchByIds(missing.filter { !$0.hasPrefix("work:") })
            extraSnaps = Dictionary(uniqueKeysWithValues: fetched.map { ($0.video_id, $0) })
        }
    }
}

// MARK: - 编辑主页

/// 兑换 VIP 页: 输入兑换码走 redeem_code (服务端验码), 成功后刷新会话等级。
/// (入口曾在旧「我的」页里, v4.0 改版换主页时丢了, 这里正式补回: 设置 + 抽屉各一个入口)
struct RedeemView: View {
    @EnvironmentObject var session: Session
    @State private var code = ""
    @State private var note = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                Text("输入站主发放的兑换码，兑换 VIP 时长，兑换后立即生效。")
                    .font(.callout).foregroundColor(.secondary)
            }
            Section("兑换码") {
                TextField("输入兑换码", text: $code)
                    .autocapitalization(.allCharacters)
                    .autocorrectionDisabled(true)
                Button("粘贴") {
                    if let s = UIPasteboard.general.string {
                        code = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
            Section {
                Button(busy ? "兑换中…" : "立即兑换") { Task { await redeem() } }
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
            if !note.isEmpty { Section { Text(note).font(.callout) } }
        }
        .navigationTitle("兑换 VIP")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func redeem() async {
        guard let me = session.username else { note = "请先登录"; return }
        busy = true
        let r = await AccountAPI.redeem(user: me, code: code)
        note = r.msg
        if r.ok {
            code = ""
            await session.validateSession()
        }
        busy = false
    }
}

/// 封禁申诉页: 被封禁用户唯一能发出的消息, 每小时限一条 (服务端 send_appeal 验权+限流)
struct AppealView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var note = ""
    @State private var sending = false

    var body: some View {
        Form {
            Section {
                Text("你的账号已被封禁，无法发表任何言论（评论、弹幕、私信、留言板、作品都不能发）。如需解封，可以在这里向站主申诉，每小时只能发送一条。")
                    .font(.callout)
            }
            Section("申诉内容") {
                TextField("说明情况…", text: $draft)
            }
            if session.appealWaitSeconds > 0 {
                Section {
                    Text("刚申诉过，请约 \(Int(ceil(Double(session.appealWaitSeconds) / 60.0))) 分钟后再发下一条")
                        .foregroundColor(.secondary)
                }
            }
            Section {
                Button(sending ? "发送中…" : "发送申诉") { Task { await send() } }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || sending || session.appealWaitSeconds > 0)
            }
            if !note.isEmpty { Section { Text(note).font(.callout) } }
        }
        .navigationTitle("联系站主申诉")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        .task { await session.fetchBanStatus() }
    }

    private func send() async {
        sending = true
        struct R: Decodable { var ok: Bool?; var message: String? }
        let rows: [R]? = try? await SB.rpc("send_appeal", params: [
            "p_token": session.loginToken,
            "p_content": draft.trimmingCharacters(in: .whitespacesAndNewlines)])
        if rows?.first?.ok == true {
            note = "已发送，站主会看到你的申诉。下一次可发送时间：1 小时后。"
            draft = ""
        } else {
            note = rows?.first?.message ?? "发送失败，请稍后再试"
        }
        await session.fetchBanStatus()
        sending = false
    }
}

struct ProfileEditView: View {
    let profile: UserProfile?
    var onSaved: () -> Void
    @Environment(\.presentationMode) private var presentationMode
    @State private var nickname = ""
    @State private var bio = ""
    @State private var avatarURL = ""
    @State private var coverURL = ""
    @State private var showPicker = false
    @State private var pickForCover = false
    @State private var uploading = false
    @State private var saving = false
    @State private var note: String? = nil

    var body: some View {
        Form {
            Section(header: Text("头像")) {
                HStack(spacing: 12) {
                    CachedImage(urlString: avatarURL)
                        .frame(width: 54, height: 54)
                        .clipShape(Circle())
                    Button(uploading ? "上传中…" : "从相册选头像") {
                        pickForCover = false
                        showPicker = true
                    }
                    .disabled(uploading)
                }
                TextField("或粘贴头像图片链接", text: $avatarURL)
            }
            Section(header: Text("封面")) {
                CachedImage(urlString: coverURL)
                    .frame(height: 90)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .cornerRadius(8)
                Button(uploading ? "上传中…" : "从相册选封面") {
                    pickForCover = true
                    showPicker = true
                }
                .disabled(uploading)
                TextField("或粘贴封面图片链接", text: $coverURL)
            }
            Section(header: Text("资料")) {
                TextField("昵称", text: $nickname)
                TextField("简介", text: $bio)
            }
            if let note = note {
                Section { Text(note).font(.footnote).foregroundColor(Theme.sub) }
            }
            Section {
                Button(saving ? "保存中…" : "保存") { Task { await save() } }
                    .disabled(saving || uploading)
            }
        }
        .navigationTitle("编辑主页")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            nickname = profile?.nickname ?? ""
            bio = profile?.bio ?? ""
            avatarURL = profile?.avatar_url ?? ""
            coverURL = profile?.cover_url ?? ""
        }
        .sheet(isPresented: $showPicker) {
            MediaPicker(onPick: { url, isVideo in
                showPicker = false
                if !isVideo { Task { await uploadPicked(url) } }
            })
        }
    }

    private func uploadPicked(_ url: URL) async {
        uploading = true
        defer { uploading = false }
        guard var data = try? Data(contentsOf: url) else {
            note = "读取图片失败"
            return
        }
        if let img = UIImage(data: data), let jpg = img.jpegData(compressionQuality: 0.82) {
            data = jpg
        }
        if let link = await Uploader.upload(data: data, filename: "profile.jpg", mime: "image/jpeg") {
            if pickForCover { coverURL = link } else { avatarURL = link }
            note = "图片已上传, 记得点保存"
        } else {
            note = "上传失败, 可以改用粘贴图片链接"
        }
    }

    private func save() async {
        saving = true
        let ok = await ProfileAPI.save(nickname: nickname, avatar: avatarURL, cover: coverURL, bio: bio)
        saving = false
        if ok {
            onSaved()
            presentationMode.wrappedValue.dismiss()
        } else {
            note = "保存失败, 检查网络或重新登录后再试"
        }
    }
}

// MARK: - 设置 (站主功能在这里)

struct SettingsView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var bridge: Bridge
    @AppStorage("vdb_autonext") private var autoNext = true
    @State private var saver = AppSettings.dataSaver
    @State private var cacheText = CacheTool.sizeText()

    var body: some View {
        List {
            Section(header: Text("播放")) {
                Toggle("连播自动下一条", isOn: $autoNext)
                Toggle("省流量模式 (蜂窝网络不预加载)", isOn: $saver)
                    .onChange(of: saver) { AppSettings.dataSaver = $0 }
            }
            Section(header: Text("通用")) {
                NavigationLink { AccountSwitcherView() } label: {
                    Label("切换账号", systemImage: "arrow.left.arrow.right")
                }
                NavigationLink { DevicesView() } label: {
                    Label("我的设备", systemImage: "iphone")
                }
                NavigationLink { ErrLogView() } label: {
                    Label("错误日志", systemImage: "ladybug")
                }
                HStack {
                    Label("热更新", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Text(bridge.statusText)
                        .font(.caption)
                        .foregroundColor(Theme.sub)
                    Button("检查") { Task { await bridge.checkUpdate(manual: true) } }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Theme.gold2)
                }
                Button {
                    CacheTool.clear()
                    cacheText = CacheTool.sizeText()
                } label: {
                    HStack {
                        Label("清理缓存", systemImage: "trash")
                            .foregroundColor(Theme.text)
                        Spacer()
                        Text(cacheText).foregroundColor(Theme.sub)
                    }
                }
            }
            if session.isAdmin || session.isOwner {
                Section(header: Text("站主功能")) {
                    NavigationLink { AdminView() } label: {
                        Label("站主控制台", systemImage: "crown")
                    }
                    NavigationLink { AuditLogView() } label: {
                        Label("审计日志", systemImage: "list.clipboard")
                    }
                    NavigationLink { LeaderboardView() } label: {
                        Label("作者排行榜", systemImage: "chart.bar")
                    }
                }
            }
            if session.isLoggedIn {
                Section(header: Text("兑换")) {
                    NavigationLink { RedeemView() } label: {
                        Label("兑换 VIP", systemImage: "ticket")
                    }
                }
            }
            Section(header: Text("关于")) {
                HStack {
                    Text("版本")
                    Spacer()
                    Text("v4.6").foregroundColor(Theme.sub)
                }
                if session.isLoggedIn {
                    Button(role: .destructive) { session.logout() } label: {
                        Text("退出登录")
                    }
                }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 创作者中心

struct CreatorCenterView: View {
    @EnvironmentObject var session: Session
    @State private var myWorks: [WorkItem] = []
    @State private var likeCount = 0
    @State private var playItem: VideoItem? = nil

    var body: some View {
        List {
            Section(header: Text("数据")) {
                HStack {
                    Text("发布作品")
                    Spacer()
                    Text("\(myWorks.count)").foregroundColor(Theme.sub)
                }
                HStack {
                    Text("累计获赞")
                    Spacer()
                    Text("\(likeCount)").foregroundColor(Theme.sub)
                }
            }
            Section(header: Text("我的作品")) {
                if myWorks.isEmpty {
                    Text("还没有发布过作品").foregroundColor(Theme.sub)
                }
                ForEach(myWorks) { w in
                    Button { playItem = w.asVideoItem } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(w.title ?? "无标题")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Theme.text)
                                .lineLimit(1)
                            Text(String((w.created_at ?? "").prefix(10)))
                                .font(.caption2).foregroundColor(Theme.sub)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                NavigationLink { WorkSubmitView() } label: {
                    Label("发布新作品", systemImage: "plus.circle")
                }
                NavigationLink { WorksView() } label: {
                    Label("作品广场", systemImage: "square.grid.2x2")
                }
            }
        }
        .navigationTitle("创作者中心")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let me = session.username ?? ""
            let all = await SocialAPI.works()
            myWorks = all.filter { $0.author == me }
            likeCount = await ProfileAPI.receivedLikes()
        }
        .sheet(item: $playItem) { v in
            NavigationView { PlayerView(video: v) }
        }
    }
}

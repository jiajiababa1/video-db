import SwiftUI
import UIKit

/// 首页 v2: 搜索栏 + 精选轮播 + 频道胶囊 + 继续观看 + 栏目货架 + 推荐流
struct HomeView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var bridge: Bridge
    @State private var latest: [VideoItem] = []
    @State private var hx: [VideoItem] = []
    @State private var recs: [VideoItem] = []
    @State private var loading = true
    @State private var notices: [Announcement] = []
    @State private var heroIdx = 0
    @State private var didLoad = false
    @State private var showLinkPlay = false

    private var continueWatching: [VideoItem] {
        library.history.prefix(10).compactMap { library.snapshots[$0] }
    }

    private var heroes: [VideoItem] { Array(latest.prefix(5)) }

    private static var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 0..<5: return "夜深了"
        case 5..<11: return "上午好"
        case 11..<13: return "中午好"
        case 13..<18: return "下午好"
        default: return "晚上好"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.greeting)
                            .font(.system(size: 20, weight: .heavy))
                            .foregroundColor(Theme.text)
                        Text("看看今天有什么新片")
                            .font(.caption).foregroundColor(Theme.sub)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                searchBar
                if !notices.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(notices) { n in
                            Text("📢 " + [n.title, n.content].compactMap { $0 }.joined(separator: ": "))
                                .font(.system(size: 12.5))
                                .foregroundColor(Theme.text.opacity(0.9))
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .glassPanel(10)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                }
                if let ann = bridge.announcement, !ann.isEmpty {
                    Text(ann)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.gold2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 13).padding(.vertical, 9)
                        .glassPanel(12)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                }
                if !heroes.isEmpty {
                    heroCarousel
                }
                channelChips
                ForEach(bridge.shelfOrder, id: \.self) { key in
                    switch key {
                    case "continue":
                        if !continueWatching.isEmpty {
                            shelfHeader("继续观看")
                            shelf(continueWatching, showProgress: true)
                        }
                    case "latest":
                        shelfHeader("最新上线", latestLink: true)
                        shelf(latest)
                    case "hsex":
                        shelfHeader("Hsex 专栏", section: FeedService.allSections[8])
                        shelf(hx)
                    default:
                        shelfHeader("为你推荐")
                        VideoGrid(items: recs)
                            .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("2048 影院")
        .sheet(isPresented: $showLinkPlay) {
            NavigationView { LinkPlayView() }
        }
        .task { await load() }
        .refreshable { await load(force: true) }
        .overlay { if loading { ProgressView().tint(Theme.gold) } }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            guard !heroes.isEmpty else { return }
            withAnimation { heroIdx = (heroIdx + 1) % heroes.count }
        }
    }

    private var searchBar: some View {
        NavigationLink {
            SearchView()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                Text("搜视频、作者…")
                Spacer()
            }
            .font(.system(size: 14))
            .foregroundColor(Theme.sub)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .glassCapsule()
            .padding(.horizontal, 16)
            .padding(.top, 6)
        }
        .buttonStyle(.plain)
    }

    private var heroCarousel: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $heroIdx) {
                ForEach(Array(heroes.enumerated()), id: \.element.id) { i, v in
                    NavigationLink {
                        PlayerView(video: v)
                    } label: {
                        heroView(v)
                    }
                    .buttonStyle(.plain)
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 216)
            HStack(spacing: 5) {
                ForEach(heroes.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == heroIdx ? Color.white : Color.white.opacity(0.35))
                        .frame(width: i == heroIdx ? 16 : 6, height: 4)
                }
            }
            .padding(.bottom, 8)
        }
        .padding(.top, 2)
    }

    private func heroView(_ v: VideoItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            CachedImage(urlString: v.thumbnail_url)
                .frame(height: 216)
                .frame(maxWidth: .infinity)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.88)],
                           startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 7) {
                Text("今日精选")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Theme.gold).foregroundColor(.white)
                    .cornerRadius(99)
                Text(v.displayTitle)
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundColor(.white)
                HStack(spacing: 10) {
                    Text("▶ 播放")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Color.white).foregroundColor(.black)
                        .cornerRadius(99)
                    Text("@" + v.displayAuthor)
                        .font(.caption).foregroundColor(.white.opacity(0.85))
                }
            }
            .padding(14)
        }
        .cornerRadius(16)
        .padding(.horizontal, 16)
    }

    private var channelChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                NavigationLink {
                    SwipeFeedView()
                } label: {
                    chipLabel("📱 刷视频", hot: true)
                }
                .buttonStyle(.plain)
                NavigationLink {
                    FollowFeedView()
                } label: {
                    chipLabel("❤️ 关注", hot: false)
                }
                .buttonStyle(.plain)
                NavigationLink {
                    TodayFeedView()
                } label: {
                    chipLabel("🆕 今日新增", hot: false)
                }
                .buttonStyle(.plain)
                ForEach(FeedService.allSections.filter { !$0.id.isEmpty }) { sec in
                    NavigationLink {
                        FeedView(section: sec)
                    } label: {
                        chipLabel(sec.name, hot: false)
                    }
                    .buttonStyle(.plain)
                }
                NavigationLink {
                    SectionsView()
                } label: {
                    chipLabel("🧭 全部栏目", hot: false)
                }
                .buttonStyle(.plain)
                Button {
                    showLinkPlay = true
                } label: {
                    chipLabel("🔗 贴链接播", hot: false)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private func chipLabel(_ text: String, hot: Bool) -> some View {
        Text(text)
            .font(.system(size: 13.5, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(hot ? Theme.gold : Theme.surface2)
            .foregroundColor(.white)
            .cornerRadius(99)
    }

    private func shelfHeader(_ title: String, section: AppSection? = nil, latestLink: Bool = false) -> some View {
        HStack {
            Text(title).font(.system(size: 17, weight: .bold))
            Spacer()
            if latestLink {
                // 最新上线 = 全站按时间倒序 (与刷视频「最新」同口径), 不是 latest 栏目 tag
                NavigationLink {
                    FeedView(navTitle: "最新上线")
                } label: {
                    Text("更多 ›").font(.caption).foregroundColor(Theme.gold2)
                }
            } else if let sec = section {
                NavigationLink {
                    FeedView(section: sec)
                } label: {
                    Text("更多 ›").font(.caption).foregroundColor(Theme.gold2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func shelf(_ items: [VideoItem], showProgress: Bool = false) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(items) { v in
                    NavigationLink {
                        PlayerView(video: v)
                    } label: {
                        VideoCard(video: v, progress: showProgress ? library.progress[v.video_id] : nil)
                            .frame(width: 218)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func load(force: Bool = false) async {
        // 从播放页返回时 .task 会重跑: 已有数据就别再整批替换, 否则滚动位置被打回顶部
        if didLoad && !force { return }
        didLoad = true
        // 先显缓存 (秒开), 再拉新数据替换
        if latest.isEmpty, let c = FeedCache.read(FeedCache.homeKey("latest")) { latest = visible(c.items) }
        if hx.isEmpty, let c = FeedCache.read(FeedCache.homeKey("hsex")) { hx = visible(c.items) }
        if recs.isEmpty, let c = FeedCache.read(FeedCache.homeKey("recs")) { recs = visible(c.items) }
        loading = latest.isEmpty
        async let a = FeedService.fetchPage(page: 1)
        async let b = FeedService.fetchPage(section: FeedService.allSections[8], page: 1)
        async let c = FeedService.fetchPage(section: FeedService.allSections[1], page: 1)
        if let r = try? await a {
            latest = visible(r.items)
            FeedCache.write(FeedCache.homeKey("latest"), items: r.items, total: r.total)
        }
        if let r = try? await b {
            hx = visible(r.items)
            FeedCache.write(FeedCache.homeKey("hsex"), items: r.items, total: r.total)
        }
        if let r = try? await c {
            recs = visible(r.items)
            FeedCache.write(FeedCache.homeKey("recs"), items: r.items, total: r.total)
        }
        loading = false
        notices = await ExtrasAPI.announcements()
    }

    private func visible(_ rows: [VideoItem]) -> [VideoItem] {
        rows.filter {
            !library.blockedAuthors.contains($0.displayAuthor)
                && !library.isHidden($0.video_id)
                && !library.titleBlocked($0.title)
        }
    }
}

/// 粘贴链接直接播 (借鉴 VLC 的网络串流入口): 贴一个 mp4/m3u8 直链立刻播,
/// 播完可像站内视频一样收藏 (收藏的是链接快照, 在片库里能再打开)
struct LinkPlayView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var note = ""
    @State private var playItem: VideoItem? = nil

    var body: some View {
        Form {
            Section {
                TextField("粘贴视频直链 (mp4 / m3u8)", text: $link)
                    .autocapitalization(.never)
                    .autocorrectionDisabled(true)
                Button("从剪贴板粘贴") {
                    if let s = UIPasteboard.general.string {
                        link = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            } footer: {
                Text("支持 http/https 的 mp4、m3u8 直链。在外面看到好视频, 贴进来就能看。")
            }
            if !note.isEmpty {
                Section { Text(note).font(.callout).foregroundColor(.red) }
            }
            Section {
                Button("开始播放") { start() }
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle("粘贴链接播放")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("取消") { dismiss() }
            }
        }
        .background(
            NavigationLink(isActive: Binding(
                get: { playItem != nil },
                set: { if !$0 { playItem = nil } }
            )) {
                if let v = playItem { PlayerView(video: v) }
            } label: { EmptyView() }
            .hidden()
        )
    }

    private func start() {
        let s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("http"), s.contains(".mp4") || s.contains(".m3u8") else {
            note = "链接不对: 需要 http 开头、包含 .mp4 或 .m3u8 的视频直链"
            return
        }
        note = ""
        playItem = VideoItem(video_id: "link:" + String(abs(s.hashValue)),
                             title: "外部链接视频", author: "", thumbnail_url: nil,
                             duration: s, source_section: nil, views: nil, has_mp4: true,
                             needs_rescrape: nil, video_url: nil, vote_up: nil, vote_down: nil,
                             created_at: nil, monsnode_video_id: nil, source_page: nil,
                             playable: true, vip_early: nil)
    }
}

import SwiftUI

/// 通用视频流页 (栏目 / 作者 / 搜索词 / 个人列表 共用, 带分页)
struct FeedView: View {
    var section: AppSection? = nil
    var author: String? = nil
    var search: String? = nil
    var personalIds: [String]? = nil
    var navTitle: String? = nil

    @EnvironmentObject var session: Session
    @EnvironmentObject var library: Library
    @State private var items: [VideoItem] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var loading = false
    @State private var playableOnly = true
    @State private var hotSort = false
    @State private var total: Int? = nil

    private var title: String {
        navTitle ?? section?.name ?? (author.map { "@" + $0 } ?? (search ?? "视频"))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                authorBar
                if section?.id == "hsex", session.isOwner {
                    HsexScrapeBar()
                        .padding(.horizontal, 16)
                }
                filterBar
                    .padding(.horizontal, 16)
                if let t = total {
                    Text("共 \(t) 条")
                        .font(.caption).foregroundColor(Theme.sub)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                }
                VideoGrid(items: items, onReachEnd: { loadMore() })
                    .padding(.horizontal, 12)
                if loading { ProgressView().tint(Theme.gold).padding() }
                if !loading && items.isEmpty {
                    Text("这里还没有视频")
                        .foregroundColor(Theme.sub)
                        .padding(.top, 60)
                }
            }
            .padding(.vertical, 12)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await initialLoad() }
        .refreshable { await reload() }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            chip("最新", active: !hotSort) { hotSort = false; Task { await reload() } }
            chip("最热", active: hotSort) { hotSort = true; Task { await reload() } }
            Spacer()
            chip(playableOnly ? "✅ 只看可播" : "全部", active: playableOnly) {
                playableOnly.toggle()
                Task { await reload() }
            }
        }
    }

    private func chip(_ text: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13, weight: active ? .bold : .regular))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(active ? Theme.text : Theme.surface2)
                .foregroundColor(active ? .black : Theme.sub)
                .cornerRadius(99)
        }
    }

    private var cacheKey: String {
        FeedCache.key(section: section, author: author, search: search,
                      personal: personalIds != nil, playableOnly: playableOnly, hot: hotSort)
    }

    private func visible(_ rows: [VideoItem]) -> [VideoItem] {
        rows.filter {
            !library.blockedAuthors.contains($0.displayAuthor)
                && !library.isHidden($0.video_id)
                && !library.titleBlocked($0.title)
        }
    }

    @ViewBuilder
    private var authorBar: some View {
        if let a = author {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Theme.goldGradient)
                    Text(String(a.prefix(1))).font(.headline).foregroundColor(.black)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("@" + a).font(.system(size: 16, weight: .bold))
                    Text("作者主页").font(.caption).foregroundColor(Theme.sub)
                }
                Spacer()
                Button(library.isFollowing(a) ? "已关注" : "+ 关注") { library.toggleFollow(a) }
                    .font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(library.isFollowing(a) ? Theme.surface2 : Theme.gold)
                    .foregroundColor(library.isFollowing(a) ? Theme.text : .black)
                    .cornerRadius(99)
                Button(library.isBlocked(a) ? "已屏蔽" : "屏蔽") { library.toggleBlock(a) }
                    .font(.system(size: 13))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Theme.surface2)
                    .foregroundColor(Theme.sub)
                    .cornerRadius(99)
            }
            .padding(12)
            .background(Theme.surface)
            .cornerRadius(14)
            .padding(.horizontal, 16)
        }
    }

    /// 首次进入: 先显缓存, 再静默刷新第一页
    private func initialLoad() async {
        if personalIds == nil, let c = FeedCache.read(cacheKey), !c.items.isEmpty {
            items = visible(c.items)
            total = c.total
            page = 2
            hasMore = c.items.count >= FeedService.pageSize
        }
        await reload()
    }

    private func reload() async {
        page = 1
        hasMore = true
        loading = true
        let r = try? await FeedService.fetchPage(
            section: section, playableOnly: playableOnly, author: author,
            search: search, personalIds: personalIds, page: 1, hotSort: hotSort)
        if let r = r {
            items = visible(r.items)
            if let t = r.total { total = t }
            hasMore = r.items.count >= FeedService.pageSize
            page = 2
            if personalIds == nil {
                FeedCache.write(cacheKey, items: r.items, total: r.total)
            }
        }
        loading = false
    }

    private func loadMore() {
        guard !loading, hasMore else { return }
        loading = true
        Task {
            let r = try? await FeedService.fetchPage(
                section: section, playableOnly: playableOnly, author: author,
                search: search, personalIds: personalIds, page: page, hotSort: hotSort)
            if let r = r {
                let seen = Set(items.map { $0.video_id })
                items.append(contentsOf: visible(r.items).filter { !seen.contains($0.video_id) })
                if let t = r.total { total = t }
                hasMore = r.items.count >= FeedService.pageSize
                page += 1
            } else {
                hasMore = false
            }
            loading = false
        }
    }
}

/// Hsex 专属抓取条 (站主, 与网站按钮同: ghDispatch mode=hsex + 字节进度)
struct HsexScrapeBar: View {
    @EnvironmentObject var session: Session
    @State private var busy = false
    @State private var note: String? = nil
    @State private var progress: Double? = nil

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("🕷️ 专属抓取").font(.subheadline.weight(.bold))
                Text(note ?? "站主专属 · 只抓本栏目")
                    .font(.caption).foregroundColor(Theme.sub)
                if let p = progress {
                    ProgressView(value: p).tint(Theme.gold)
                }
            }
            Spacer()
            Button(busy ? "抓取中…" : "开始抓取") {
                Task { await trigger() }
            }
            .font(.system(size: 13, weight: .bold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.goldGradient)
            .foregroundColor(.black)
            .cornerRadius(99)
            .disabled(busy)
        }
        .padding(12)
        .background(Theme.surface)
        .cornerRadius(14)
    }

    private func trigger() async {
        let token = session.ghToken
        guard !token.isEmpty else { note = "先在「我的」里填 GitHub 令牌"; return }
        busy = true
        note = "正在触发…"
        let ok = await GitHub.dispatch(mode: "hsex", token: token)
        if !ok {
            note = "触发失败, 检查令牌"
            busy = false
            return
        }
        note = "已触发, 云端抓取中…"
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            if let st = await GitHub.latestRunState(token: token) {
                progress = st.progress
                if st.status == "completed" {
                    note = st.conclusion == "success" ? "抓取完成, 下拉刷新看新片" : "运行结束: \(st.conclusion ?? "")"
                    break
                }
            }
        }
        busy = false
    }
}

import SwiftUI

/// 搜索页: 输入联想 (作者/热门标题) + 服务端相关性搜索 (search_videos)
struct SearchView: View {
    @EnvironmentObject var library: Library
    @State private var query = ""
    @State private var submitted = ""
    @State private var hotAuthors: [String] = []
    @State private var suggestions: [FeedService.Suggest] = []
    @State private var suggestTask: Task<Void, Never>? = nil

    /// 热门作者: 优先读服务端排行榜缓存 (真实观看量 Top 10), 读不到再采样估算
    private func loadHotAuthors() async {
        struct CRow: Decodable { var name: String? }
        let (cache, _): ([CRow], Int?) = (try? await SB.get(
            "rest/v1/leaderboard_authors_cache",
            query: [
                URLQueryItem(name: "select", value: "name"),
                URLQueryItem(name: "order", value: "total_views.desc"),
                URLQueryItem(name: "limit", value: "10"),
            ])) ?? ([], nil)
        let names = cache.compactMap { $0.name }.filter { !$0.isEmpty }
        if !names.isEmpty {
            hotAuthors = names
            return
        }
        struct ARow: Decodable { var author: String? }
        let url = SB.base.absoluteString + "/rest/v1/videos?select=author&removed=not.is.true&order=created_at.desc&limit=300"
        let (rows, _): ([ARow], Int?) = (try? await SB.getRaw(url)) ?? ([], nil)
        var counts: [String: Int] = [:]
        for r in rows {
            if let a = r.author, !a.isEmpty { counts[a, default: 0] += 1 }
        }
        hotAuthors = counts.sorted { $0.value > $1.value }.prefix(10).map { $0.key }
    }

    private func submit(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        query = t
        submitted = t
        suggestions = []
        library.pushSearchRecent(t)
    }

    /// 输入联想: 防抖 300ms, 只认最后一次输入的结果
    private func scheduleSuggest() {
        suggestTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, q != submitted else { suggestions = []; return }
        suggestTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let s = await FeedService.searchSuggest(q: q)
            if Task.isCancelled { return }
            suggestions = s
        }
    }

    private var showingSuggestions: Bool {
        !suggestions.isEmpty && !query.trimmingCharacters(in: .whitespaces).isEmpty
            && query.trimmingCharacters(in: .whitespaces) != submitted
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(Theme.sub)
                TextField("搜视频、作者… 多个词用空格隔开", text: $query)
                    .submitLabel(.search)
                    .onSubmit { submit(query) }
                    .onChange(of: query) { _ in scheduleSuggest() }
                if !query.isEmpty {
                    Button {
                        query = ""; submitted = ""; suggestions = []
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(Theme.sub)
                    }
                }
                Button("搜索") { submit(query) }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Theme.gold2)
            }
            .padding(.horizontal, 13).padding(.vertical, 10)
            .glassCapsule()
            .padding(16)

            if showingSuggestions {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(suggestions.enumerated()), id: \.offset) { _, s in
                            if s.kind == "author", let name = s.txt, !name.isEmpty {
                                NavigationLink { AuthorView(name: name) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "person.circle.fill")
                                            .foregroundColor(Theme.gold2)
                                        Text("@" + name).foregroundColor(Theme.text).lineLimit(1)
                                        Spacer()
                                        Text("作者").font(.caption).foregroundColor(Theme.sub)
                                    }
                                    .padding(.vertical, 9)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            } else if let w = s.txt, !w.isEmpty {
                                Button { submit(w) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "magnifyingglass")
                                            .foregroundColor(Theme.sub)
                                        Text(w).foregroundColor(Theme.text).lineLimit(1)
                                        Spacer()
                                    }
                                    .padding(.vertical, 9)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            Divider().background(Theme.surface2)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            } else if submitted.isEmpty {
                if !hotAuthors.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("热门作者").font(.system(size: 14, weight: .bold))
                        LinkChips(items: hotAuthors) { a in
                            NavigationLink {
                                AuthorView(name: a)
                            } label: {
                                Text("@" + a)
                                    .font(.system(size: 13))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(Theme.surface2)
                                    .foregroundColor(Theme.text)
                                    .cornerRadius(99)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                }
                if library.searchRecent.isEmpty {
                    Text("输入关键词搜全站视频\n支持标题和作者名, 多个词空格隔开会全部命中")
                        .multilineTextAlignment(.center)
                        .foregroundColor(Theme.sub)
                        .padding(.top, 50)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("最近搜索").font(.system(size: 14, weight: .bold))
                            Spacer()
                            Button("清空") { library.clearSearchRecent() }
                                .font(.caption).foregroundColor(Theme.sub)
                        }
                        ForEach(library.searchRecent, id: \.self) { r in
                            Button { submit(r) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .foregroundColor(Theme.sub)
                                    Text(r).foregroundColor(Theme.text).lineLimit(1)
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                Spacer()
            } else {
                SearchResultsView(query: submitted)
                    .id(submitted)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadHotAuthors() }
    }
}

/// 搜索结果: 走服务端 search_videos (多词全中 + 相关性排序), 分页加载
struct SearchResultsView: View {
    let query: String
    @EnvironmentObject var library: Library
    @State private var items: [VideoItem] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var loading = false
    @State private var playableOnly = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    chip(playableOnly ? "✅ 只看可播" : "全部", active: playableOnly) {
                        playableOnly.toggle()
                        Task { await reload() }
                    }
                    Spacer()
                    Text("按相关度排序")
                        .font(.caption).foregroundColor(Theme.sub)
                }
                .padding(.horizontal, 16)
                if loading && items.isEmpty {
                    SkeletonGrid().padding(.horizontal, 12)
                }
                VideoGrid(items: items, onReachEnd: { loadMore() })
                    .padding(.horizontal, 12)
                if loading && !items.isEmpty {
                    ProgressView().tint(Theme.gold).padding()
                }
                if !loading && hasMore && !items.isEmpty {
                    Button("加载更多") { loadMore() }
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundColor(Theme.gold2)
                        .padding(.vertical, 6)
                }
                if !loading && items.isEmpty {
                    Text("没搜到「\(query)」\n换个关键词, 或把词拆开用空格分隔试试")
                        .multilineTextAlignment(.center)
                        .foregroundColor(Theme.sub)
                        .padding(.top, 50)
                }
            }
            .padding(.vertical, 12)
        }
        .task { await reload() }
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

    private func visible(_ rows: [VideoItem]) -> [VideoItem] {
        rows.filter {
            !library.blockedAuthors.contains($0.displayAuthor)
                && !library.isHidden($0.video_id)
                && !library.titleBlocked($0.title)
        }
    }

    private func reload() async {
        page = 1
        hasMore = true
        loading = true
        let rows = await FeedService.searchVideos(q: query, page: 1, playableOnly: playableOnly)
        items = visible(rows)
        hasMore = rows.count >= FeedService.pageSize
        loading = false
    }

    private func loadMore() {
        guard hasMore, !loading else { return }
        Task { await loadMoreAsync() }
    }

    private func loadMoreAsync() async {
        loading = true
        let next = page + 1
        let rows = await FeedService.searchVideos(q: query, page: next, playableOnly: playableOnly)
        page = next
        let known = Set(items.map { $0.video_id })
        items += visible(rows).filter { !known.contains($0.video_id) }
        hasMore = rows.count >= FeedService.pageSize
        loading = false
    }
}

/// 简单流式布局: 一排排自动换行的 chips (iOS15 无 Layout 协议, 用横滑单行代替复杂实现)
struct LinkChips<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { content($0) }
            }
        }
    }
}

import SwiftUI
import AVKit
import AVFoundation

/// 「刷视频」v3 (抖音式):
/// - 翻页: 三页跟手滑动, 松手整页吸附; 手势只挂视频区, 右侧按钮栏/顶栏固定不动,
///   任何视频上功能都完整可点 (v1.9 按钮跟页滑动+被手势抢事件是"不好用"的主因)。
/// - 画面: 封面模糊放大做氛围背景 + 视频按原比例完整显示, 横竖屏切换不再跳变。
/// - 当前条前后各 1 条提前解链+预缓冲, 翻过去直接播。
/// - 双击画面 = 收藏 (爱心动画); 单击 = 暂停/播放。
/// - 三模式: 最新 / 热门 / 随机, 全程去重。
struct SwipeFeedView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var session: Session
    @Environment(\.vdbTabActive) private var tabActive
    var dockInset: Bool = false
    @StateObject private var ctrl = SwipeController()
    @State private var items: [VideoItem] = []
    @State private var seenIds: Set<String> = []
    @State private var index = 0
    @State private var page = 1
    @State private var hasMore = true
    @State private var loading = false
    @State private var mode = 0            // 0 最新 1 热门 2 随机
    @State private var totalCount: Int? = nil
    @State private var dragOffset: CGFloat = 0
    @State private var paging = false
    @State private var pageH: CGFloat = 800
    @State private var showComments = false
    @State private var showShare = false
    @State private var heartTick = 0       // 双击爱心动画触发计数
    @State private var likeLiked = false   // 真点赞状态 (当前视频)
    @State private var likeTotal = 0       // 真点赞数 (当前视频)

    private var current: VideoItem? { items.indices.contains(index) ? items[index] : nil }
    private var prevItem: VideoItem? { items.indices.contains(index - 1) ? items[index - 1] : nil }
    private var nextItem: VideoItem? { items.indices.contains(index + 1) ? items[index + 1] : nil }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // 视频页区 (手势只在这一层)
                ZStack {
                    if let pv = prevItem {
                        pageLayer(pv, isCurrent: false)
                            .offset(y: dragOffset - geo.size.height)
                    }
                    if let v = current {
                        pageLayer(v, isCurrent: true)
                            .offset(y: dragOffset)
                    } else if loading {
                        ProgressView().tint(.white)
                    } else {
                        Text("暂无可播视频").foregroundColor(Theme.sub)
                    }
                    if let nv = nextItem {
                        pageLayer(nv, isCurrent: false)
                            .offset(y: dragOffset + geo.size.height)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(swipeGesture(height: geo.size.height))
                .onTapGesture(count: 2) { doubleTapFav() }
                .onTapGesture(count: 1) { ctrl.togglePlay() }

                // 固定层: 顶栏 + 右侧栏 + 底部进度 (不跟页滑动)
                topBar
                if let v = current {
                    fixedRail(v)
                    bottomProgress(v)
                    if ctrl.userPaused {
                        Image(systemName: "play.fill")
                            .font(.system(size: 52))
                            .foregroundColor(.white.opacity(0.85))
                            .shadow(radius: 8)
                    }
                    if heartTick > 0 {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 84))
                            .foregroundColor(Theme.gold)
                            .shadow(radius: 12)
                            .id(heartTick)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .onAppear {
                pageH = geo.size.height
                dragOffset = 0
                if !showComments { ctrl.resumeActive() }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("刷视频")
        .task {
            ctrl.onEnded = { goNext() }
            await initialLoad()
        }
        .onDisappear { ctrl.stop() }
        .onChange(of: tabActive) { active in
            // Dock 模式下切走 Tab 自动暂停, 切回自动恢复 (导航 push 进来时不受影响)
            if dockInset {
                if active { ctrl.resumeActive() } else { ctrl.pauseActive() }
            }
        }
        .onChange(of: index) { _ in startCurrent() }
        .sheet(isPresented: $showComments, onDismiss: { ctrl.resumeActive() }) {
            if let v = current {
                CommentsSheet(video: v)
            }
        }
        .sheet(isPresented: $showShare) {
            if let v = current {
                ActivityView(items: [URL(string: "https://jiajiababa1.github.io/video-db/watch.html?v=" + v.video_id)!])
            }
        }
    }

    // MARK: - 单页 (氛围背景 + 原比例画面 + 底部信息)

    private func pageLayer(_ v: VideoItem, isCurrent: Bool) -> some View {
        ZStack {
            // 氛围背景: 封面放大模糊铺满, 横竖屏都不会黑边突兀
            // drawingGroup 把模糊结果栅格化成单张纹理缓存, 翻页动画不再逐帧重算模糊 (性能)
            CachedImage(urlString: v.thumbnail_url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .blur(radius: 48)
                .scaleEffect(1.6)
                .opacity(0.75)
                .clipped()
                .drawingGroup()
            if isCurrent, ctrl.activePlayer != nil {
                SwipePlayerLayer(ctrl: ctrl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 邻居页/未就绪: 封面铺满裁剪, 与播放层 (resizeAspectFill) 构图一致, 切换不跳
                CachedImage(urlString: v.thumbnail_url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if isCurrent, !ctrl.readyIds.contains(v.video_id), !ctrl.failedIds.contains(v.video_id) {
                ProgressView().tint(.white)
            }
            // 底部信息 (跟页走)
            VStack {
                Spacer()
                VStack(alignment: .leading, spacing: 5) {
                    if !v.displayAuthor.isEmpty {
                        Text("@" + v.displayAuthor)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                    }
                    Text(v.displayTitle)
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(3)
                    HStack(spacing: 8) {
                        if let t = v.viewsText {
                            Text(t + " 观看")
                        }
                        if let d = v.created_at, !d.isEmpty {
                            Text(String(d.prefix(10)))
                        }
                    }
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.65))
                    if isCurrent, ctrl.failedIds.contains(v.video_id) {
                        Text("⚠️ 这条解链失败, 已标记重爬 — 上滑看下一条")
                            .font(.caption).foregroundColor(.yellow)
                    }
                }
                .shadow(radius: 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 14)
                .padding(.trailing, 76)   // 给右侧栏让位
                .padding(.bottom, dockInset ? 104 : 30)
            }
        }
    }

    // MARK: - 固定层

    private var topBar: some View {
        VStack {
            HStack {
                Spacer()
                Picker("模式", selection: $mode) {
                    Text("最新").tag(0)
                    Text("热门").tag(1)
                    Text("随机").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .colorScheme(.dark)
                .padding(3)
                .glassCapsule(live: true)
                .onChange(of: mode) { _ in Task { await reload() } }
                Spacer()
            }
            .padding(.horizontal, 50)
            .padding(.top, 6)
            Spacer()
        }
    }

    private func fixedRail(_ v: VideoItem) -> some View {
        VStack {
            Spacer()
            VStack(spacing: 16) {
                if !v.displayAuthor.isEmpty {
                    VStack(spacing: 0) {
                        NavigationLink {
                            AuthorView(name: v.displayAuthor)
                        } label: {
                            ZStack {
                                Circle().fill(Theme.surface2)
                                Text(String(v.displayAuthor.prefix(1)))
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            .frame(width: 46, height: 46)
                            .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded { ctrl.pauseActive() })
                        if !library.isFollowing(v.displayAuthor) {
                            Button {
                                library.toggleFollow(v.displayAuthor)
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .heavy))
                                    .foregroundColor(.white)
                                    .frame(width: 19, height: 19)
                                    .background(Theme.gold)
                                    .clipShape(Circle())
                            }
                            .offset(y: -9)
                        }
                    }
                }
                railButton(likeLiked ? "heart.fill" : "heart",
                           likeLiked ? Theme.gold : .white,
                           likeTotal > 0 ? "\(likeTotal)" : "点赞") {
                    Task { await tapLike(v) }
                }
                railButton("text.bubble.fill", .white, "评论") {
                    ctrl.pauseActive()
                    showComments = true
                }
                railButton(library.isWatchLater(v.video_id) ? "clock.fill" : "clock", .white, "稍后看") {
                    library.toggleWatchLater(v)
                }
                railButton("square.and.arrow.up", .white, "分享") {
                    showShare = true
                }
                NavigationLink {
                    PlayerView(video: v)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "rectangle.expand.vertical")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                            .frame(width: 46, height: 46)
                            .glassCircle()
                        Text("详情")
                            .font(.caption2)
                            .foregroundColor(.white)
                    }
                    .shadow(radius: 4)
                }
                .simultaneousGesture(TapGesture().onEnded { ctrl.pauseActive() })
            }
            .padding(.trailing, 10)
            .padding(.bottom, dockInset ? 128 : 64)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .task(id: v.video_id) { await refreshLike(v) }
    }

    private func railButton(_ icon: String, _ color: Color, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 21))
                    .foregroundColor(color)
                    .frame(width: 46, height: 46)
                    .glassCircle()
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.white)
            }
            .shadow(radius: 4)
        }
    }

    private func bottomProgress(_ v: VideoItem) -> some View {
        VStack {
            Spacer()
            if ctrl.duration > 0 && !ctrl.failedIds.contains(v.video_id) {
                ProgressView(value: min(ctrl.current / ctrl.duration, 1))
                    .progressViewStyle(.linear)
                    .tint(Theme.gold)
                    .padding(.bottom, dockInset ? 84 : 0)
            }
        }
    }

    // MARK: - 互动

    /// 拉当前视频的真点赞状态
    private func refreshLike(_ v: VideoItem) async {
        let s = await LikesAPI.status(v.video_id)
        if current?.video_id == v.video_id {
            likeLiked = s.liked
            likeTotal = s.total
        }
    }

    /// 点右侧爱心: 登录走真点赞接口; 未登录退回本地收藏表现
    private func tapLike(_ v: VideoItem) async {
        guard session.isLoggedIn else {
            library.toggleFav(v)
            return
        }
        if let r = await LikesAPI.toggle(v.video_id) {
            likeLiked = r.liked
            likeTotal = r.total
        }
    }

    private func doubleTapFav() {
        guard let v = current else { return }
        if session.isLoggedIn {
            // 双击只点赞不取消 (抖音式), 先本地点亮再向服务端确认
            if !likeLiked {
                likeLiked = true
                likeTotal += 1
                Task {
                    if let r = await LikesAPI.toggle(v.video_id) {
                        likeLiked = r.liked
                        likeTotal = r.total
                    }
                }
            }
        } else if !library.isFav(v.video_id) {
            library.toggleFav(v)
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) { heartTick += 1 }
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            withAnimation(.easeOut(duration: 0.25)) { heartTick = 0 }
        }
    }

    // MARK: - 翻页手势 (跟手 + 吸附)

    private func swipeGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { g in
                guard !paging, !showComments else { return }
                let dy = g.translation.height
                if (index == 0 && dy > 0) || (nextItem == nil && dy < 0) {
                    dragOffset = dy * 0.35
                } else {
                    dragOffset = dy
                }
            }
            .onEnded { g in
                guard !paging else { return }
                let predicted = g.predictedEndTranslation.height
                if predicted < -height * 0.35 {
                    if nextItem != nil {
                        flip(to: index + 1, direction: -1, height: height)
                    } else {
                        springBack()
                        if hasMore {
                            Task {
                                await loadMore()
                                if nextItem != nil { flip(to: index + 1, direction: -1, height: height) }
                            }
                        }
                    }
                } else if predicted > height * 0.35, index > 0 {
                    flip(to: index - 1, direction: 1, height: height)
                } else {
                    springBack()
                }
            }
    }

    private func springBack() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { dragOffset = 0 }
    }

    private func flip(to newIndex: Int, direction: CGFloat, height: CGFloat) {
        guard !paging, items.indices.contains(newIndex) else { return }
        paging = true
        withAnimation(.easeOut(duration: 0.22)) { dragOffset = direction * height }
        Task {
            try? await Task.sleep(nanoseconds: 225_000_000)
            index = newIndex
            dragOffset = 0
            paging = false
        }
    }

    private func goNext() {
        if nextItem != nil {
            flip(to: index + 1, direction: -1, height: pageH)
        } else if hasMore {
            Task {
                await loadMore()
                if nextItem != nil { flip(to: index + 1, direction: -1, height: pageH) }
            }
        }
    }

    // MARK: - 数据

    private func startCurrent() {
        guard let v = current else { return }
        library.recordWatch(v)
        Task { await ViewCounter.register(video: v, user: session.username, library: library) }
        ctrl.syncWindow(items: items, index: index)
        if items.count - index <= 4, hasMore { Task { await loadMore() } }
    }

    private func initialLoad() async {
        if items.isEmpty { await reload() }
    }

    private func reload() async {
        loading = true
        index = 0
        page = 1
        hasMore = true
        items = []
        seenIds = []
        dragOffset = 0
        let batch = await fetchBatch()
        appendBatch(batch)
        loading = false
        startCurrent()
    }

    private func loadMore() async {
        guard hasMore, !loading else { return }
        loading = true
        page += 1
        let batch = await fetchBatch()
        if batch.isEmpty {
            if mode == 2 {
                var extra: [VideoItem] = []
                for _ in 0..<3 where extra.count < 6 {
                    extra.append(contentsOf: await fetchBatch())
                }
                let fresh = extra.filter { !seenIds.contains($0.video_id) }
                if fresh.isEmpty { hasMore = false } else { appendBatch(fresh) }
            } else {
                hasMore = false
            }
        } else {
            appendBatch(batch)
        }
        loading = false
        ctrl.syncWindow(items: items, index: index)
    }

    private func appendBatch(_ batch: [VideoItem]) {
        for v in batch where !seenIds.contains(v.video_id) {
            seenIds.insert(v.video_id)
            items.append(v)
        }
    }

    private func fetchBatch() async -> [VideoItem] {
        switch mode {
        case 1:
            let r = (try? await FeedService.fetchPage(page: page, hotSort: true)) ?? (items: [], total: nil)
            if r.items.count < FeedService.pageSize { hasMore = false }
            return r.items
        case 2:
            if totalCount == nil { totalCount = await FeedService.totalCount() }
            let size = FeedService.pageSize
            let maxPage = max(1, (totalCount ?? size) / size)
            let p = Int.random(in: 1...maxPage)
            let r = (try? await FeedService.fetchPage(page: p)) ?? (items: [], total: nil)
            return r.items.shuffled()
        default:
            let r = (try? await FeedService.fetchPage(page: page)) ?? (items: [], total: nil)
            if r.items.count < FeedService.pageSize { hasMore = false }
            return r.items
        }
    }
}

/// 预加载播放器池: 窗口内 (当前±1) 的视频提前解链建播放器并预缓冲,
/// 激活时用 playImmediately 立刻起播, 不等缓冲填满。
final class SwipeController: ObservableObject {
    @Published var activePlayer: AVPlayer? = nil
    @Published var readyIds: Set<String> = []
    @Published var failedIds: Set<String> = []
    @Published var current: Double = 0
    @Published var duration: Double = 0
    @Published var userPaused = false
    var onEnded: (() -> Void)? = nil

    func togglePlay() {
        guard let p = activePlayer else { return }
        if p.timeControlStatus == .playing {
            p.pause()
            userPaused = true
        } else {
            userPaused = false
            p.playImmediately(atRate: 1)
        }
    }

    func pauseActive() {
        activePlayer?.pause()
    }

    func resumeActive() {
        guard !userPaused, activeId != nil, activePlayer != nil else { return }
        activePlayer?.playImmediately(atRate: 1)
    }

    private var pool: [String: AVPlayer] = [:]
    private var observers: [String: NSObjectProtocol] = [:]
    private var resolving: Set<String> = []
    private var timeToken: Any? = nil
    private var activeId: String? = nil

    func syncWindow(items: [VideoItem], index: Int) {
        guard items.indices.contains(index) else { return }
        // 省流量生效 (开关开+蜂窝): 只备当前一条, 不预加载邻居
        let windowIdx = (AppSettings.saverActive ? [index] : [index - 1, index, index + 1])
            .filter { items.indices.contains($0) }
        let keep = Set(windowIdx.map { items[$0].video_id })
        for (id, p) in pool where !keep.contains(id) {
            p.pause()
            p.replaceCurrentItem(with: nil)
            if let o = observers[id] { NotificationCenter.default.removeObserver(o) }
            observers[id] = nil
            pool[id] = nil
        }
        for i in windowIdx { ensurePlayer(items[i]) }
        activate(items[index])
    }

    private func ensurePlayer(_ v: VideoItem) {
        if pool[v.video_id] != nil || resolving.contains(v.video_id) { return }
        resolving.insert(v.video_id)
        Task {
            let url = await Resolver.resolve(v)
            await MainActor.run {
                self.resolving.remove(v.video_id)
                guard let url = url else {
                    self.failedIds.insert(v.video_id)
                    Resolver.markRescrape(v)
                    ErrLog.log("swipe", "解链失败 \(v.video_id)")
                    return
                }
                let p = AVPlayer()
                p.automaticallyWaitsToMinimizeStalling = false
                let item = AVPlayerItem(url: url)
                item.preferredForwardBufferDuration = 10
                self.observers[v.video_id] = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    if self?.activeId == v.video_id { self?.onEnded?() }
                }
                p.replaceCurrentItem(with: item)
                self.pool[v.video_id] = p
                self.readyIds.insert(v.video_id)
                if self.activeId == v.video_id {
                    self.attach(p, id: v.video_id)
                    p.playImmediately(atRate: 1)
                }
            }
        }
    }

    private func activate(_ v: VideoItem) {
        if activeId != v.video_id { userPaused = false }
        if activeId == v.video_id, let p = pool[v.video_id] {
            if activePlayer !== p { attach(p, id: v.video_id) }
            p.playImmediately(atRate: 1)
            return
        }
        if let old = activeId, let op = pool[old] { op.pause() }
        activeId = v.video_id
        current = 0
        duration = 0
        if let p = pool[v.video_id] {
            attach(p, id: v.video_id)
            p.playImmediately(atRate: 1)
        } else {
            if let t = timeToken { activePlayer?.removeTimeObserver(t); timeToken = nil }
            activePlayer = nil
            ensurePlayer(v)
        }
    }

    private func attach(_ p: AVPlayer, id: String) {
        if let t = timeToken { activePlayer?.removeTimeObserver(t); timeToken = nil }
        activePlayer = p
        timeToken = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] t in
            guard let self = self, self.activeId == id else { return }
            self.current = t.seconds
            if let d = p.currentItem?.duration.seconds, d.isFinite { self.duration = d }
        }
    }

    func stop() {
        for (_, p) in pool { p.pause() }
        if let t = timeToken { activePlayer?.removeTimeObserver(t); timeToken = nil }
        activePlayer = nil
        activeId = nil
    }

    deinit {
        for (_, o) in observers { NotificationCenter.default.removeObserver(o) }
        if let t = timeToken { activePlayer?.removeTimeObserver(t) }
    }
}

/// 无控制条的纯播放层
struct SwipePlayerLayer: UIViewRepresentable {
    @ObservedObject var ctrl: SwipeController

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = ctrl.activePlayer
        v.playerLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if uiView.playerLayer.player !== ctrl.activePlayer {
            uiView.playerLayer.player = ctrl.activePlayer
        }
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

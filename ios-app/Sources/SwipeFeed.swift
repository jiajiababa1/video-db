import SwiftUI
import AVKit
import AVFoundation

/// 「刷视频」栏目 (抖音式): 三页跟手翻页 — 拖动时上下页一起滑动露出来,
/// 松手吸附整页; 当前条的前后各 1 条提前解链+预缓冲, 翻过去直接播。
/// 三种模式: 最新 (时间流) / 热门 (观看量) / 随机 (随机页打乱), 全程去重。
struct SwipeFeedView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var session: Session
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

    private var current: VideoItem? { items.indices.contains(index) ? items[index] : nil }
    private var prevItem: VideoItem? { items.indices.contains(index - 1) ? items[index - 1] : nil }
    private var nextItem: VideoItem? { items.indices.contains(index + 1) ? items[index + 1] : nil }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if let pv = prevItem {
                    poster(pv)
                        .offset(y: dragOffset - geo.size.height)
                }
                if let v = current {
                    currentPage(v)
                        .offset(y: dragOffset)
                } else if loading {
                    ProgressView().tint(.white)
                } else {
                    Text("暂无可播视频").foregroundColor(Theme.sub)
                }
                if let nv = nextItem {
                    poster(nv)
                        .offset(y: dragOffset + geo.size.height)
                }
                topBar
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(swipeGesture(height: geo.size.height))
            .onAppear { pageH = geo.size.height }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("刷视频")
        .task {
            ctrl.onEnded = { goNext() }
            await initialLoad()
        }
        .onAppear { if !showComments { ctrl.resumeActive() } }
        .onDisappear { ctrl.stop() }
        .onChange(of: index) { _ in startCurrent() }
        .sheet(isPresented: $showComments, onDismiss: { ctrl.resumeActive() }) {
            if let v = current {
                CommentsSheet(video: v)
            }
        }
    }

    // MARK: - 页面层

    private func poster(_ v: VideoItem) -> some View {
        CachedImage(urlString: v.thumbnail_url)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func currentPage(_ v: VideoItem) -> some View {
        ZStack {
            poster(v)
            if ctrl.activePlayer != nil {
                SwipePlayerLayer(ctrl: ctrl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { ctrl.togglePlay() }
            }
            if ctrl.userPaused {
                Image(systemName: "play.fill")
                    .font(.system(size: 52))
                    .foregroundColor(.white.opacity(0.85))
                    .shadow(radius: 8)
            }
            if !ctrl.readyIds.contains(v.video_id) && !ctrl.failedIds.contains(v.video_id) {
                ProgressView().tint(.white)
            }
            overlay(v)
        }
    }

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
                .onChange(of: mode) { _ in Task { await reload() } }
                Spacer()
            }
            .padding(.horizontal, 50)
            .padding(.top, 6)
            Spacer()
        }
    }

    private func overlay(_ v: VideoItem) -> some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(v.displayTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(3)
                        .shadow(radius: 4)
                    if !v.displayAuthor.isEmpty {
                        Text("@" + v.displayAuthor)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.85))
                    }
                    if ctrl.failedIds.contains(v.video_id) {
                        Text("⚠️ 这条解链失败, 已标记重爬 — 上滑看下一条")
                            .font(.caption).foregroundColor(.yellow)
                    } else if ctrl.duration > 0 {
                        ProgressView(value: min(ctrl.current / ctrl.duration, 1))
                            .progressViewStyle(.linear)
                            .tint(Theme.gold)
                            .frame(width: 170)
                    }
                }
                Spacer()
                rail(v)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 26)
        }
    }

    private func rail(_ v: VideoItem) -> some View {
        VStack(spacing: 18) {
            railButton(library.isFav(v.video_id) ? "bookmark.fill" : "bookmark", "收藏") {
                library.toggleFav(v)
            }
            railButton(library.isWatchLater(v.video_id) ? "clock.fill" : "clock", "稍后看") {
                library.toggleWatchLater(v)
            }
            railButton("text.bubble.fill", "评论") {
                ctrl.pauseActive()
                showComments = true
            }
            NavigationLink {
                PlayerView(video: v)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "rectangle.expand.vertical").font(.system(size: 24))
                    Text("详情").font(.caption2)
                }
                .foregroundColor(.white)
                .shadow(radius: 4)
            }
            .simultaneousGesture(TapGesture().onEnded { ctrl.pauseActive() })
            railButton("shuffle", "随机") {
                mode = 2
                Task { await reload() }
            }
        }
    }

    private func railButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 24))
                Text(label).font(.caption2)
            }
            .foregroundColor(.white)
            .shadow(radius: 4)
        }
    }

    // MARK: - 翻页手势 (跟手 + 吸附)

    private func swipeGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { g in
                guard !paging else { return }
                let dy = g.translation.height
                if (index == 0 && dy > 0) || (nextItem == nil && dy < 0) {
                    dragOffset = dy * 0.35   // 到头了, 橡皮筋
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

    /// 整页滑出动画: 先把当前页滑出屏幕, 再无动画换 index (新页正好在原位), 视觉连续
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
                // 随机模式抽到的都是看过的: 再多抽几页找没看过的
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
        case 1:  // 热门: 按观看量排序, 与"最新"真正区分开
            let r = (try? await FeedService.fetchPage(page: page, hotSort: true)) ?? (items: [], total: nil)
            if r.items.count < FeedService.pageSize { hasMore = false }
            return r.items
        case 2:  // 随机: 随机页 + 打乱
            if totalCount == nil { totalCount = await FeedService.totalCount() }
            let size = FeedService.pageSize
            let maxPage = max(1, (totalCount ?? size) / size)
            let p = Int.random(in: 1...maxPage)
            let r = (try? await FeedService.fetchPage(page: p)) ?? (items: [], total: nil)
            return r.items.shuffled()
        default: // 最新: 按时间顺序翻页
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
        v.playerLayer.videoGravity = .resizeAspect
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

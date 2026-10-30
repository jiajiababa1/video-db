import SwiftUI
import AVKit
import AVFoundation

/// 「刷视频」栏目: 全屏竖滑, 上下滑切换, 自动播放下一个。
/// 性能做法 (与短视频 App 相同): 当前条的前后各 1 条提前解链+预缓冲,
/// 滑过去直接播; 未就绪时先垫封面海报, 不黑屏干等。
/// 两种模式: 最新 (按时间流) / 随机 (随机页抽取+打乱, 翻老视频)。
struct SwipeFeedView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var session: Session
    @StateObject private var ctrl = SwipeController()
    @State private var items: [VideoItem] = []
    @State private var index = 0
    @State private var page = 1
    @State private var hasMore = true
    @State private var loading = false
    @State private var randomMode = false
    @State private var totalCount: Int? = nil
    @State private var dragOffset: CGFloat = 0

    private var current: VideoItem? { items.indices.contains(index) ? items[index] : nil }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if let v = current {
                    // 海报垫底: 播放器未就绪/缓冲时不黑屏
                    CachedImage(urlString: v.thumbnail_url)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .offset(y: dragOffset)
                    if ctrl.activePlayer != nil {
                        SwipePlayerLayer(ctrl: ctrl)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .offset(y: dragOffset)
                    }
                    if !ctrl.readyIds.contains(v.video_id) && !ctrl.failedIds.contains(v.video_id) {
                        ProgressView().tint(.white)
                            .offset(y: dragOffset)
                    }
                    overlay(v)
                        .offset(y: dragOffset)
                } else if loading {
                    ProgressView().tint(Theme.gold)
                } else {
                    Text("暂无可播视频").foregroundColor(Theme.sub)
                }
                topBar
            }
            .contentShape(Rectangle())
            .gesture(swipeGesture())
        }
        .background(Color.black.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("刷视频")
        .task {
            ctrl.onEnded = { goNext() }
            await initialLoad()
        }
        .onDisappear { ctrl.stop() }
        .onChange(of: index) { _ in startCurrent() }
    }

    // MARK: - 覆盖层

    private var topBar: some View {
        VStack {
            HStack {
                Spacer()
                Picker("模式", selection: $randomMode) {
                    Text("最新").tag(false)
                    Text("随机").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .colorScheme(.dark)
                .onChange(of: randomMode) { _ in Task { await reload() } }
                Spacer()
            }
            .padding(.horizontal, 60)
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
                    Text("上下滑动切换 · 点右侧按钮看详情/评论")
                        .font(.caption2).foregroundColor(.white.opacity(0.55))
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
            NavigationLink {
                PlayerView(video: v)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "text.bubble.fill").font(.system(size: 24))
                    Text("详情").font(.caption2)
                }
                .foregroundColor(.white)
                .shadow(radius: 4)
            }
            railButton("shuffle", "随机") {
                randomMode = true
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

    // MARK: - 手势

    private func swipeGesture() -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { dragOffset = $0.translation.height }
            .onEnded { g in
                let dy = g.translation.height
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { dragOffset = 0 }
                if dy < -70 {
                    goNext()
                } else if dy > 70, index > 0 {
                    index -= 1
                }
            }
    }

    private func goNext() {
        if index + 1 < items.count {
            index += 1
        } else if hasMore {
            Task { await loadMore(); if index + 1 < items.count { index += 1 } }
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
        items = await fetchBatch()
        loading = false
        startCurrent()
    }

    private func loadMore() async {
        guard hasMore, !loading else { return }
        loading = true
        page += 1
        let batch = await fetchBatch()
        if batch.isEmpty {
            hasMore = false
        } else {
            let known = Set(items.map { $0.video_id })
            items.append(contentsOf: batch.filter { !known.contains($0.video_id) })
        }
        loading = false
        // 列表变长后把预加载窗口补齐 (滑到尾部时下一条可能刚入库)
        ctrl.syncWindow(items: items, index: index)
    }

    private func fetchBatch() async -> [VideoItem] {
        if randomMode {
            if totalCount == nil { totalCount = await FeedService.totalCount() }
            let size = FeedService.pageSize
            let maxPage = max(1, (totalCount ?? size) / size)
            let p = Int.random(in: 1...maxPage)
            let r = (try? await FeedService.fetchPage(page: p)) ?? (items: [], total: nil)
            return r.items.shuffled()
        }
        let r = (try? await FeedService.fetchPage(page: page)) ?? (items: [], total: nil)
        if r.items.count < FeedService.pageSize { hasMore = false }
        return r.items
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
    var onEnded: (() -> Void)? = nil

    private var pool: [String: AVPlayer] = [:]
    private var observers: [String: NSObjectProtocol] = [:]
    private var resolving: Set<String> = []
    private var timeToken: Any? = nil
    private var activeId: String? = nil

    func syncWindow(items: [VideoItem], index: Int) {
        guard items.indices.contains(index) else { return }
        let windowIdx = [index - 1, index, index + 1].filter { items.indices.contains($0) }
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

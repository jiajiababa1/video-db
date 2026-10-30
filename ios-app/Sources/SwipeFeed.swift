import SwiftUI
import AVKit
import AVFoundation

/// 「刷视频」栏目: 全屏竖滑, 上下滑切换, 自动播放下一个。
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
    @State private var failedCurrent = false

    private var current: VideoItem? { items.indices.contains(index) ? items[index] : nil }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if let v = current {
                    SwipePlayerLayer(ctrl: ctrl)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .offset(y: dragOffset)
                    overlay(v, height: geo.size.height)
                        .offset(y: dragOffset)
                } else if loading {
                    ProgressView().tint(Theme.gold)
                } else {
                    Text("暂无可播视频").foregroundColor(Theme.sub)
                }
                topBar
            }
            .contentShape(Rectangle())
            .gesture(swipeGesture(height: geo.size.height))
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

    private func overlay(_ v: VideoItem, height: CGFloat) -> some View {
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
                    if failedCurrent {
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

    private func swipeGesture(height: CGFloat) -> some Gesture {
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
        failedCurrent = false
        guard let v = current else { return }
        library.recordWatch(v)
        Task { await ViewCounter.register(video: v, user: session.username, library: library) }
        ctrl.play(video: v) { ok in
            if !ok {
                failedCurrent = true
                Resolver.markRescrape(v)
                ErrLog.log("swipe", "解链失败 \(v.video_id)")
            }
        }
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

/// 单播放器控制器: 切视频时换源, 播完自动回调
final class SwipeController: ObservableObject {
    @Published var current: Double = 0
    @Published var duration: Double = 0
    let player = AVPlayer()
    private var token: Any? = nil
    private var endObserver: NSObjectProtocol? = nil
    var onEnded: (() -> Void)? = nil

    init() {
        token = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                               queue: .main) { [weak self] t in
            guard let self = self else { return }
            self.current = t.seconds
            if let d = self.player.currentItem?.duration.seconds, d.isFinite { self.duration = d }
        }
    }

    func play(video: VideoItem, onResult: @escaping (Bool) -> Void) {
        player.pause()
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs); endObserver = nil }
        current = 0
        duration = 0
        Task {
            let url = await Resolver.resolve(video)
            await MainActor.run {
                guard let url = url else { onResult(false); return }
                let item = AVPlayerItem(url: url)
                self.endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    self?.onEnded?()
                }
                self.player.replaceCurrentItem(with: item)
                self.player.play()
                onResult(true)
            }
        }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    deinit {
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs) }
        if let t = token { player.removeTimeObserver(t) }
    }
}

/// 无控制条的纯播放层
struct SwipePlayerLayer: UIViewRepresentable {
    @ObservedObject var ctrl: SwipeController

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = ctrl.player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if uiView.playerLayer.player !== ctrl.player {
            uiView.playerLayer.player = ctrl.player
        }
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

import SwiftUI
import AVKit
import AVFoundation
import UIKit

/// 系统安全区尺寸 (刷视频全屏沉浸时, 顶栏/底部元素手动避让状态栏与小横条用)
enum ScreenInsets {
    private static var insets: UIEdgeInsets {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first(where: { $0.isKeyWindow })?.safeAreaInsets ?? .zero
    }
    static var top: CGFloat { insets.top }
    static var bottom: CGFloat { insets.bottom }
}

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
    @State private var showWatched = false // 看完一遍后临时关掉"看过过滤"重看 (仅本次运行)
    @State private var totalCount: Int? = nil
    @State private var dragOffset: CGFloat = 0
    @State private var paging = false
    @State private var pageH: CGFloat = 800
    @State private var showComments = false
    @State private var showShare = false
    @State private var heartTick = 0       // 双击爱心动画触发计数
    @State private var likeLiked = false   // 真点赞状态 (当前视频)
    @State private var likeTotal = 0       // 真点赞数 (当前视频)
    // (v4.1 起刷视频只是栏目里的一条入口, 不再有左上角片库弹窗 —— 弹窗与底下
    //  刷视频声音重叠的问题随之根除; 打开搜索/分享时也会先暂停)
    @State private var showSearch = false
    @State private var friendWorks: [VideoItem]? = nil  // 互关模式缓存
    @State private var authorName = ""     // 左滑进作者主页: 目标作者 + 跳转开关
    @State private var showAuthor = false

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
                        VStack(spacing: 14) {
                            Text(mode == 3
                                 ? "还没有互关好友发布的作品\n去「朋友」加好友, 或在「我的」里发布作品"
                                 : (dockInset && !showWatched
                                    ? "新视频都看完啦 🎉\n看过的不再重复出现 (历史每天一清, 明天又能刷)"
                                    : "暂无可播视频"))
                                .foregroundColor(Theme.sub)
                                .multilineTextAlignment(.center)
                            if dockInset, !showWatched, mode != 3 {
                                Button("重新看一遍") {
                                    showWatched = true
                                    Task { await reload() }
                                }
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(Theme.gold2)
                                .padding(.horizontal, 18).padding(.vertical, 9)
                                .glassCapsule()
                            }
                        }
                    }
                    if let nv = nextItem {
                        pageLayer(nv, isCurrent: false)
                            .offset(y: dragOffset + geo.size.height)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .contentShape(Rectangle())
                .simultaneousGesture(swipeGesture(height: geo.size.height))
                .onTapGesture(count: 2) { doubleTapFav() }
                .onTapGesture(count: 1) { ctrl.togglePlay() }
                // 长按倍速必须与翻页拖动"同时识别": 旧版把长按和独占拖动手势叠在同一层,
                // 手势仲裁把长按饿死, 永远触发不了 (用户实测无效)。改 simultaneous 后
                // 按满 0.5 秒 onChanged 进倍速, 抬手 onEnded 恢复; 滑动翻页也会顺手结束倍速。
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5, maximumDistance: 20)
                        .onChanged { _ in
                            if !ctrl.boosting {
                                ctrl.beginBoost()
                                if ctrl.boosting { Haptics.light() }
                            }
                        }
                        .onEnded { _ in ctrl.endBoost() }
                )
                // 左滑进作者主页: 水平位移过 80 且竖直漂移小才算 (不抢上下翻页)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { g in
                            ctrl.endBoost()
                            guard !showComments, !paging else { return }
                            if g.translation.width < -80, abs(g.translation.height) < 60,
                               let v = current, !v.displayAuthor.isEmpty {
                                authorName = v.displayAuthor
                                showAuthor = true
                            }
                        }
                )

                // 左滑跳转的目标 (隐藏链接, 由手势置位触发)
                NavigationLink(destination: AuthorView(name: authorName), isActive: $showAuthor) {
                    EmptyView()
                }
                .hidden()

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
                if ctrl.boosting {
                    Text("⚡ 2x 快进中")
                        .font(.system(size: 12.5, weight: .bold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.black.opacity(0.65))
                        .foregroundColor(.yellow)
                        .cornerRadius(99)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.trailing, 14)
                        .padding(.bottom, dockInset ? 142 : 40)
                        .allowsHitTesting(false)
                }
            }
            .onAppear {
                pageH = geo.size.height
                dragOffset = 0
                if !showComments { ctrl.resumeActive() }
            }
        }
        .ignoresSafeArea(dockInset ? .all : [])
        .background(Color.black.ignoresSafeArea())
        .navigationBarHidden(dockInset)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("刷视频")
        .task {
            ctrl.onEnded = { goNext() }
            ctrl.onFailed = {
                // 坏视频自动跳过: 先让封面+提示闪一下 (0.7 秒), 还停在这条就翻下一条
                Task {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    if let c = current, ctrl.failedIds.contains(c.video_id) { goNext() }
                }
            }
            await initialLoad()
        }
        .onAppear { ChromeState.shared.hidden = true }
        .onDisappear { ctrl.stop(); ChromeState.shared.hidden = false }
        .onChange(of: tabActive) { active in
            // Dock 模式下切走 Tab 自动暂停, 切回自动恢复 (导航 push 进来时不受影响)
            if dockInset {
                if active { ctrl.resumeActive() } else { ctrl.pauseActive() }
            }
        }
        .onChange(of: index) { _ in startCurrent() }
        .onChange(of: session.accountGeneration) { _ in
            // 换账号后当前视频的点赞状态按新账号重拉 (点赞记录每人一份)
            if let v = current { Task { await refreshLike(v) } }
        }
        .sheet(isPresented: $showComments, onDismiss: { ctrl.resumeActive() }) {
            if let v = current {
                CommentsSheet(video: v)
            }
        }
        .sheet(isPresented: $showShare, onDismiss: { ctrl.resumeActive() }) {
            if let v = current {
                ActivityView(items: [URL(string: "https://jiajiababa1.github.io/video-db/watch.html?v=" + v.video_id)!])
            }
        }
        .sheet(isPresented: $showSearch, onDismiss: { ctrl.resumeActive() }) {
            NavigationView { SearchView() }
        }
    }

    // MARK: - 单页 (氛围背景 + 原比例画面 + 底部信息)

    private func pageLayer(_ v: VideoItem, isCurrent: Bool) -> some View {
        ZStack {
            // 纯黑底: 库里横竖屏视频混杂 (实测约 1/3 横屏 16:9、2/3 竖屏),
            // 统一按原比例完整显示 —— 横屏居中留黑, 竖屏满高, 不裁不拉伸
            Color.black
            // 封面常驻垫底: 播放层就绪前先看封面, 链接坏了也停在封面上, 不再整屏黑
            CachedImage(urlString: v.thumbnail_url, fit: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if isCurrent, ctrl.activePlayer != nil {
                SwipePlayerLayer(ctrl: ctrl)
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
                .padding(.bottom, dockInset ? 118 : 30)
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
                    Text("互关").tag(3)
                }
                .pickerStyle(.segmented)
                .frame(width: 216)
                .colorScheme(.dark)
                .padding(3)
                .glassCapsule(live: true)
                .onChange(of: mode) { _ in Task { await reload() } }
                Spacer()
                Button { ctrl.pauseActive(); showSearch = true } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .glassCircle()
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, dockInset ? ScreenInsets.top + 2 : 6)
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
                    ctrl.pauseActive(); showShare = true
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
            .padding(.bottom, dockInset ? 118 : 64)
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

    /// 底部进度条: 当前时间 / 进度 / 总时长, 整条可拖动快进快退
    private func bottomProgress(_ v: VideoItem) -> some View {
        VStack {
            Spacer()
            if ctrl.duration > 0 && !ctrl.failedIds.contains(v.video_id) {
                GeometryReader { geo in
                    HStack(spacing: 8) {
                        Text(timeText(ctrl.current))
                        ProgressView(value: min(max(ctrl.current / ctrl.duration, 0), 1))
                            .progressViewStyle(.linear)
                            .tint(Theme.gold)
                        Text(timeText(ctrl.duration))
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .shadow(radius: 3)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                let f = min(max(g.location.x / max(geo.size.width, 1), 0), 1)
                                ctrl.seekFraction(f)
                            }
                    )
                }
                .frame(height: 22)
                .padding(.horizontal, 14)
                .padding(.bottom, dockInset ? 106 : 6)
            }
        }
    }

    private func timeText(_ s: Double) -> String {
        let t = Int(max(0, s))
        return String(format: "%d:%02d", t / 60, t % 60)
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
                if abs(dy) > 10, ctrl.boosting { ctrl.endBoost() }
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
        await pump(minItems: 12)
        // 每次进来换个开头: 第一批随机旋转一下, 不再总是同一条 (仅刷视频主页)
        if dockInset, items.count > 6 {
            let cut = Int.random(in: 1...(items.count / 2))
            items = Array(items[cut...]) + Array(items[..<cut])
        }
        loading = false
        startCurrent()
    }

    private func loadMore() async {
        guard hasMore, !loading else { return }
        loading = true
        await pump(minItems: items.count + 1)
        loading = false
        ctrl.syncWindow(items: items, index: index)
    }

    /// 连续取批直到攒够 minItems 条: 看过的被过滤后单批可能不足, 自动翻下一页补;
    /// 最多 5 轮防死循环 (随机模式整批都看过时靠它收尾)
    private func pump(minItems: Int) async {
        var rounds = 0
        while items.count < minItems, hasMore, rounds < 5 {
            let batch = await fetchBatch()
            appendBatch(batch)
            if mode == 0 || mode == 1 { page += 1 }
            if batch.isEmpty, mode != 2 { hasMore = false }
            rounds += 1
        }
    }

    private func appendBatch(_ batch: [VideoItem]) {
        for v in batch where !seenIds.contains(v.video_id) {
            // 刷视频专属逻辑 (仅主页实例): 看过的不再出现; 列表/片库/搜索不受影响
            if dockInset, !showWatched, library.isWatched(v.video_id) { continue }
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
            // 服务端表采样随机取片 (每次都是新的一批, seenIds 负责去重)
            return await FeedService.fetchRandom()
        case 3:
            // 互关: 互为好友的用户发布的作品 (一次取全, 不分页)
            if friendWorks == nil {
                friendWorks = await FeedService.fetchFriendWorks(me: session.username)
            }
            if page > 1 { return [] }
            hasMore = false
            return friendWorks ?? []
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
    @Published var boosting = false   // 长按 2 倍速中
    var onEnded: (() -> Void)? = nil
    var onFailed: (() -> Void)? = nil
    private var statusObs: [String: NSKeyValueObservation] = [:]

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

    /// 长按倍速: 按满 0.5 秒才由手势 perform 调用 (普通点击不触发); 抬手 endBoost 恢复 1x
    func beginBoost() {
        guard let p = activePlayer, !userPaused,
              p.timeControlStatus == .playing
                || p.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
        boosting = true
        p.rate = 2
    }

    func endBoost() {
        guard boosting else { return }
        boosting = false
        if let p = activePlayer, p.timeControlStatus == .playing { p.rate = 1 }
    }

    /// 进度条拖动: 按比例跳转 (带容差, 拖动更顺)
    func seekFraction(_ f: Double) {
        guard let p = activePlayer, duration > 0 else { return }
        let tol = CMTime(seconds: 0.4, preferredTimescale: 600)
        p.seek(to: CMTime(seconds: f * duration, preferredTimescale: 600),
               toleranceBefore: tol, toleranceAfter: tol)
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
            statusObs[id] = nil
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
                    if self.activeId == v.video_id { self.onFailed?() }
                    return
                }
                let p = AVPlayer()
                p.automaticallyWaitsToMinimizeStalling = false
                let item = AVPlayerItem(url: url)
                item.preferredForwardBufferDuration = 10
                self.observers[v.video_id] = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    guard let self = self, self.activeId == v.video_id else { return }
                    // 刷视频循环播放 (抖音式): 播完从头再播; 用户手动暂停着就不打扰
                    if !self.userPaused, let p = self.pool[v.video_id] {
                        p.seek(to: .zero)
                        p.playImmediately(atRate: 1)
                    }
                }
                // 真就绪/真失败都听播放条目自己的状态: 以前没监听, 坏链接 (403/过期签名)
                // 会永远停在黑屏 —— 这就是"有的视频黑屏"的根因
                let obs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        if it.status == .readyToPlay {
                            self.readyIds.insert(v.video_id)
                        } else if it.status == .failed, !self.failedIds.contains(v.video_id) {
                            self.failedIds.insert(v.video_id)
                            Resolver.markRescrape(v)
                            ErrLog.log("swipe", "播放失败 \(v.video_id): \(it.error?.localizedDescription ?? "?")")
                            if self.activeId == v.video_id { self.onFailed?() }
                        }
                    }
                }
                self.statusObs[v.video_id] = obs
                p.replaceCurrentItem(with: item)
                self.pool[v.video_id] = p
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
        // 看门狗: 10 秒还没就绪 (链接挂死/服务器不响应) 按失败处理, 界面会自动跳下一条
        let vid = v.video_id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await MainActor.run {
                guard let self = self, self.activeId == vid,
                      !self.readyIds.contains(vid), !self.failedIds.contains(vid) else { return }
                self.failedIds.insert(vid)
                Resolver.markRescrape(v)
                ErrLog.log("swipe", "播放超时 \(vid)")
                self.onFailed?()
            }
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
        v.playerLayer.videoGravity = .resizeAspect
        v.bind(ctrl.activePlayer)
        return v
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if uiView.playerLayer.player !== ctrl.activePlayer {
            uiView.bind(ctrl.activePlayer)
        }
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        private var readyObs: NSKeyValueObservation?

        /// 换播放器先把画面藏起来, 等第一帧真显示出来 (isReadyForDisplay) 再淡入:
        /// 否则播放层一挂上先是一帧黑, 每次翻页都会"闪一下" (底下封面垫着, 淡入正好盖住交接)
        func bind(_ p: AVPlayer?) {
            readyObs = nil
            playerLayer.player = p
            guard p != nil else { alpha = 0; return }
            alpha = playerLayer.isReadyForDisplay ? 1 : 0
            readyObs = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if layer.isReadyForDisplay {
                        UIView.animate(withDuration: 0.18) { self.alpha = 1 }
                    } else {
                        self.alpha = 0
                    }
                }
            }
        }
    }
}

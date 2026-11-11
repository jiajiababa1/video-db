import SwiftUI
import AVKit

/// 苹果原生播放器: AVPlayerViewController + 系统控制条
/// (播放/暂停、原生进度条、全屏、画中画、隔空播放、系统倍速菜单全走原生)
struct PlayerVC: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = true
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
        vc.showsPlaybackControls = true
    }
}

final class PlayerVM: ObservableObject {
    @Published var player: AVPlayer? = nil
    @Published var state: String = "loading"   // loading / ready / failed
    @Published var rate: Float = 1
    @Published var sleepNote: String? = nil
    @Published var resolvedURL: URL? = nil
    @Published var currentTime: Double = 0
    @Published var durationTime: Double = 0
    var scrubbing = false
    private var tickCount = 0
    var video: VideoItem
    private var token: Any? = nil
    private var seekDone = false
    private var sleepTimer: Timer? = nil
    weak var library: Library?

    init(video: VideoItem) { self.video = video }

    func setRate(_ r: Float) {
        rate = r
        if let p = player, p.timeControlStatus == .playing { p.rate = r }
    }

    // 长按临时加速 (松手恢复原速)
    @Published var boosting = false
    private var rateBeforeBoost: Float = 1

    func beginBoost() {
        guard !boosting, player != nil else { return }
        boosting = true
        rateBeforeBoost = rate
        if let p = player, p.timeControlStatus == .playing { p.rate = 2 }
    }

    func endBoost() {
        guard boosting else { return }
        boosting = false
        if let p = player, p.timeControlStatus == .playing { p.rate = rateBeforeBoost }
    }

    func seek(by seconds: Double) {
        guard let p = player, let item = p.currentItem else { return }
        let target = max(0, p.currentTime().seconds + seconds)
        let dur = item.duration.seconds
        p.seek(to: CMTime(seconds: dur.isFinite ? min(target, dur - 0.5) : target, preferredTimescale: 600))
    }

    func scrub(to seconds: Double) {
        guard let p = player else { return }
        currentTime = seconds
        p.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
               toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setSleep(minutes: Int) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        guard minutes > 0 else { sleepNote = nil; return }
        sleepNote = "⏰ \(minutes) 分钟后自动暂停"
        sleepTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            self?.player?.pause()
            self?.sleepNote = "⏰ 定时时间到, 已暂停"
        }
    }

    func start(library: Library) async {
        self.library = library
        library.recordWatch(video)
        let url = await Resolver.resolve(video)
        await MainActor.run {
            guard let url = url else {
                state = "failed"
                ErrLog.log("resolve", "解链失败 \(video.video_id) \(video.displayTitle)")
                Resolver.markRescrape(video)
                return
            }
            resolvedURL = url
            let item = AVPlayerItem(url: url)
            let p = AVPlayer(playerItem: item)
            player = p
            state = "ready"
            token = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
                guard let self = self, let item = p.currentItem else { return }
                let dur = item.duration.seconds
                guard dur.isFinite, dur > 0 else { return }
                if !self.scrubbing {
                    self.currentTime = t.seconds
                    self.durationTime = dur
                }
                self.tickCount += 1
                if self.tickCount % 10 == 0 {
                    self.library?.recordWatch(self.video, progress: t.seconds / dur)
                }
                if !self.seekDone {
                    self.seekDone = true
                    if let saved = self.library?.progress[self.video.video_id], saved > 0.02, saved < 0.95 {
                        p.seek(to: CMTime(seconds: saved * dur, preferredTimescale: 600))
                    }
                }
            }
            p.play()
            // 真实观看计数 (同一账号只计一次)
            Task { await ViewCounter.register(video: video, user: Session.shared.username, library: library) }
        }
    }

    func stop() {
        player?.pause()
        sleepTimer?.invalidate()
        if let token = token { player?.removeTimeObserver(token) }
        token = nil
    }
}

/// 播放页: 苹果原生播放器 + 文案 + 操作 + 评论 + 接下来播放
struct PlayerView: View {
    let video: VideoItem
    @EnvironmentObject var library: Library
    @EnvironmentObject var session: Session
    @StateObject private var vm: PlayerVM
    @State private var upNext: [VideoItem] = []
    @State private var showShare = false
    @ObservedObject private var dl = Downloader.shared

    init(video: VideoItem) {
        self.video = video
        _vm = StateObject(wrappedValue: PlayerVM(video: video))
    }

    var body: some View {
        VStack(spacing: 0) {
            playerArea
            controlsRow
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(video.displayTitle)
                        .font(.system(size: 17, weight: .bold))
                        .lineLimit(3)
                    authorRow
                    copyBlock
                    actionsRow
                    Divider().background(Theme.line)
                    CommentsView(video: video)
                    if !upNext.isEmpty {
                        Text("接下来播放")
                            .font(.system(size: 16, weight: .bold))
                            .padding(.top, 6)
                        ForEach(upNext) { v in
                            NavigationLink {
                                PlayerView(video: v)
                            } label: {
                                nextRow(v)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await vm.start(library: library)
            await loadUpNext()
        }
        .onDisappear { vm.stop() }
        .sheet(isPresented: $showShare) {
            ActivityView(items: [shareURL])
        }
    }

    private var shareURL: URL {
        URL(string: "https://jiajiababa1.github.io/video-db/watch.html?v=" + video.video_id)!
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                    Button(r == 1 ? "1.0x 正常" : "\(r)x") { vm.setRate(Float(r)) }
                }
            } label: {
                ctrlLabel("gauge.with.dots.needle.33percent", "倍速 \(vm.rate == 1 ? "" : "\(vm.rate)x")")
            }
            Menu {
                Button("关闭定时") { vm.setSleep(minutes: 0) }
                ForEach([10, 20, 30, 60], id: \.self) { m in
                    Button("\(m) 分钟后暂停") { vm.setSleep(minutes: m) }
                }
            } label: {
                ctrlLabel("timer", "定时关闭")
            }
            Button {
                downloadCurrent()
            } label: {
                if let p = dl.progresses[video.video_id] {
                    ctrlLabel("arrow.down.circle", "下载 \(Int(p * 100))%")
                } else if dl.isDownloaded(video.video_id) {
                    ctrlLabel("checkmark.circle", "已下载")
                } else {
                    ctrlLabel("arrow.down.circle", "下载")
                }
            }
            .disabled(dl.isDownloaded(video.video_id) || dl.progresses[video.video_id] != nil)
            if let n = vm.sleepNote {
                Text(n).font(.caption2).foregroundColor(Theme.gold2).lineLimit(1)
            }
            Spacer()
            Text("点画面出原生控制条 · 长按画面 2 倍速")
                .font(.caption2).foregroundColor(Theme.sub).lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.surface)
    }

    private func ctrlLabel(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 13))
            Text(text).font(.system(size: 12.5, weight: .bold))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.surface2)
        .foregroundColor(Theme.text)
        .cornerRadius(99)
    }

    private func downloadCurrent() {
        if let u = vm.resolvedURL {
            if u.pathExtension.lowercased() == "m3u8" {
                vm.sleepNote = "该视频是流媒体格式, 暂不支持离线下载"
            } else {
                dl.enqueue(video, url: u)
            }
        } else {
            Task {
                if let u = await Resolver.resolve(video) {
                    if u.pathExtension.lowercased() == "m3u8" {
                        vm.sleepNote = "该视频是流媒体格式, 暂不支持离线下载"
                    } else {
                        dl.enqueue(video, url: u)
                    }
                }
            }
        }
    }

    private var playerArea: some View {
        ZStack {
            Color.black
            switch vm.state {
            case "ready":
                if let p = vm.player {
                    PlayerVC(player: p)
                    if vm.boosting {
                        Text("⚡ 2x 快进中")
                            .font(.system(size: 13, weight: .bold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.black.opacity(0.65))
                            .foregroundColor(.yellow)
                            .cornerRadius(99)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .padding(.top, 10)
                            .allowsHitTesting(false)
                    }
                }
            case "failed":
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(Theme.gold)
                    Text("视频加载失败, 可能已被删除或设为私密")
                        .font(.footnote).foregroundColor(Theme.sub)
                    Text("已自动标记, 爬虫会重新解析")
                        .font(.caption2).foregroundColor(Theme.sub)
                }
            default:
                ProgressView().tint(Theme.gold)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 40, pressing: { pressing in
            if pressing { vm.beginBoost() } else { vm.endBoost() }
        }, perform: {})
    }

    private var authorRow: some View {
        HStack(spacing: 10) {
            if !video.displayAuthor.isEmpty {
                NavigationLink {
                    AuthorView(name: video.displayAuthor)
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(Theme.goldGradient)
                            Text(String(video.displayAuthor.prefix(1)))
                                .font(.headline).foregroundColor(.black)
                        }
                        .frame(width: 38, height: 38)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("@" + video.displayAuthor).font(.subheadline.weight(.bold))
                                .foregroundColor(Theme.text)
                            Text((video.viewsText ?? "") + (video.durationText.map { " · " + $0 } ?? ""))
                                .font(.caption).foregroundColor(Theme.sub)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if !video.displayAuthor.isEmpty {
                Button(library.isFollowing(video.displayAuthor) ? "已关注" : "+ 关注") {
                    library.toggleFollow(video.displayAuthor)
                }
                .font(.system(size: 13, weight: .bold))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(library.isFollowing(video.displayAuthor) ? Theme.surface2 : Theme.gold)
                .foregroundColor(library.isFollowing(video.displayAuthor) ? Theme.text : .black)
                .cornerRadius(99)
            }
        }
    }

    private var copyBlock: some View {
        let lines: [String] = [
            video.displayTitle,
            video.displayAuthor.isEmpty ? nil : "作者: " + video.displayAuthor,
            video.durationText.map { "时长: " + $0 },
            video.views.map { "观看: " + $0 },
        ].compactMap { $0 }
        return Text(lines.joined(separator: "\n"))
            .font(.system(size: 13.5))
            .foregroundColor(Theme.text.opacity(0.85))
            .lineSpacing(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.surface)
            .cornerRadius(14)
    }

    private var actionsRow: some View {
        HStack(spacing: 8) {
            actionBtn(library.isFav(video.video_id) ? "bookmark.fill" : "bookmark",
                      library.isFav(video.video_id) ? "已收藏" : "收藏",
                      hot: library.isFav(video.video_id)) { library.toggleFav(video) }
            actionBtn("clock", library.isWatchLater(video.video_id) ? "已加入" : "稍后看",
                      hot: library.isWatchLater(video.video_id)) { library.toggleWatchLater(video) }
            actionBtn("square.and.arrow.up", "分享", hot: false) { showShare = true }
            if let src = video.video_url, let u = URL(string: src) {
                Link(destination: u) {
                    VStack(spacing: 5) {
                        Image(systemName: "safari").font(.system(size: 20))
                        Text("原站").font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Theme.surface)
                    .cornerRadius(14)
                    .foregroundColor(Theme.sub)
                }
            }
        }
    }

    private func actionBtn(_ icon: String, _ text: String, hot: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 20))
                Text(text).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Theme.surface)
            .cornerRadius(14)
            .foregroundColor(hot ? Theme.gold2 : Theme.sub)
        }
    }

    private func nextRow(_ v: VideoItem) -> some View {
        HStack(spacing: 11) {
            CachedImage(urlString: v.thumbnail_url)
                .frame(width: 120)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipped()
            .cornerRadius(10)
            VStack(alignment: .leading, spacing: 4) {
                Text(v.displayTitle).font(.system(size: 13.5)).lineLimit(2)
                Text("@" + v.displayAuthor + (v.viewsText.map { " · " + $0 } ?? ""))
                    .font(.caption).foregroundColor(Theme.sub)
            }
            Spacer()
        }
    }

    private func loadUpNext() async {
        let sec = FeedService.allSections.first { $0.id == (video.source_section?.split(separator: "|").first.map(String.init) ?? "") }
        let r = try? await FeedService.fetchPage(section: sec, page: 1)
        upNext = (r?.items ?? []).filter { $0.video_id != video.video_id }.prefix(8).map { $0 }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

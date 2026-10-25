import SwiftUI
import AVKit
import MediaPlayer

/// AVPlayerViewController 包装: 原生控制条 + 画中画
struct PlayerVC: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
    }
}

/// 隐形音量锚点 (手势调音量用)
struct VolumeAnchor: UIViewRepresentable {
    static weak var slider: UISlider?

    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView()
        v.alpha = 0.001
        DispatchQueue.main.async {
            VolumeAnchor.slider = v.subviews.compactMap { $0 as? UISlider }.first
        }
        return v
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}

    static func setVolume(_ value: Float) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            slider?.value = value
        }
    }
}

final class PlayerVM: ObservableObject {
    @Published var player: AVPlayer? = nil
    @Published var state: String = "loading"   // loading / ready / failed
    @Published var rate: Float = 1
    @Published var sleepNote: String? = nil
    @Published var resolvedURL: URL? = nil
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

    func seek(by seconds: Double) {
        guard let p = player, let item = p.currentItem else { return }
        let target = max(0, p.currentTime().seconds + seconds)
        let dur = item.duration.seconds
        p.seek(to: CMTime(seconds: dur.isFinite ? min(target, dur - 0.5) : target, preferredTimescale: 600))
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
                Resolver.markRescrape(video)
                return
            }
            resolvedURL = url
            let item = AVPlayerItem(url: url)
            let p = AVPlayer(playerItem: item)
            player = p
            state = "ready"
            token = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { [weak self] t in
                guard let self = self, let item = p.currentItem else { return }
                let dur = item.duration.seconds
                guard dur.isFinite, dur > 0 else { return }
                let frac = t.seconds / dur
                if !self.seekDone {
                    self.seekDone = true
                    if let saved = self.library?.progress[self.video.video_id], saved > 0.02, saved < 0.95 {
                        p.seek(to: CMTime(seconds: saved * dur, preferredTimescale: 600))
                    }
                }
                self.library?.recordWatch(self.video, progress: frac)
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

/// 播放页: 原生 AVPlayer + 文案 + 操作 + 评论 + 接下来播放
struct PlayerView: View {
    let video: VideoItem
    @EnvironmentObject var library: Library
    @EnvironmentObject var session: Session
    @StateObject private var vm: PlayerVM
    @State private var upNext: [VideoItem] = []
    @State private var showShare = false
    @State private var gestureHint: String? = nil
    @State private var dragStart: CGFloat? = nil
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
            Text("双击两侧快退/快进 · 上下滑动调亮度/音量")
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

    @ViewBuilder
    private var playerArea: some View {
        ZStack {
            Color.black
            switch vm.state {
            case "ready":
                if let p = vm.player {
                    PlayerVC(player: p)
                    gestureStrip(left: true)
                    gestureStrip(left: false)
                    VolumeAnchor().frame(width: 1, height: 1)
                    if let h = gestureHint {
                        Text(h)
                            .font(.system(size: 15, weight: .bold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Color.black.opacity(0.65))
                            .foregroundColor(.white)
                            .cornerRadius(99)
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

    /// 两侧手势条: 双击快退/快进, 上下拖动调亮度(左)/音量(右)
    private func gestureStrip(left: Bool) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: 58)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: left ? .leading : .trailing)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                vm.seek(by: left ? -10 : 10)
                flash(left ? "⏪ 快退 10 秒" : "⏩ 快进 10 秒")
            }
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { v in
                        if dragStart == nil {
                            dragStart = left ? UIScreen.main.brightness
                                : CGFloat(AVAudioSession.sharedInstance().outputVolume)
                        }
                        let nv = min(max((dragStart ?? 0) - v.translation.height / 260, 0), 1)
                        if left {
                            UIScreen.main.brightness = nv
                            flash("☀️ 亮度 \(Int(nv * 100))%")
                        } else {
                            VolumeAnchor.setVolume(Float(nv))
                            flash("🔊 音量 \(Int(nv * 100))%")
                        }
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }

    private func flash(_ s: String) {
        gestureHint = s
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            if gestureHint == s { gestureHint = nil }
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

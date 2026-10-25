import SwiftUI
import AVKit

final class PlayerVM: ObservableObject {
    @Published var player: AVPlayer? = nil
    @Published var state: String = "loading"   // loading / ready / failed
    var video: VideoItem
    private var token: Any? = nil
    private var seekDone = false
    weak var library: Library?

    init(video: VideoItem) { self.video = video }

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
        }
    }

    func stop() {
        player?.pause()
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

    init(video: VideoItem) {
        self.video = video
        _vm = StateObject(wrappedValue: PlayerVM(video: video))
    }

    var body: some View {
        VStack(spacing: 0) {
            playerArea
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

    @ViewBuilder
    private var playerArea: some View {
        ZStack {
            Color.black
            switch vm.state {
            case "ready":
                if let p = vm.player {
                    VideoPlayer(player: p)
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
            ZStack {
                Circle().fill(Theme.goldGradient)
                Text(String(video.displayAuthor.prefix(1)))
                    .font(.headline).foregroundColor(.black)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text("@" + video.displayAuthor).font(.subheadline.weight(.bold))
                Text((video.viewsText ?? "") + (video.durationText.map { " · " + $0 } ?? ""))
                    .font(.caption).foregroundColor(Theme.sub)
            }
            Spacer()
            if !video.displayAuthor.isEmpty {
                Button(library.isFollowing(video.displayAuthor) ? "已关注" : "+ 关注") {
                    library.toggleFollow(video.displayAuthor)
                }
                .font(.system(size: 13, weight: .bold))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(library.isFollowing(video.displayAuthor) ? Theme.surface2 : Theme.goldGradient)
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
            AsyncImage(url: URL(string: v.thumbnail_url ?? "")) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default: Rectangle().fill(Theme.surface2)
                }
            }
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

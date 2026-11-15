import SwiftUI
import AVKit

/// 迷你播放器 (v5.0, 学 FreeTube 的小窗): 在播放页点「小窗」, 播放器缩到屏幕角落继续播,
/// 人去刷列表/看别的页, 点小窗回到全屏播放页, 点 ✕ 关闭。
/// 实现: 直接接管 PlayerView 那个 AVPlayer 实例 (不重新加载, 进度无缝)。
final class MiniPlayerState: ObservableObject {
    static let shared = MiniPlayerState()

    @Published var player: AVPlayer? = nil
    @Published var video: VideoItem? = nil
    @Published var playing: Bool = false
    @Published var offset: CGSize = .zero
    var baseOffset: CGSize = .zero
    private var obs: Any? = nil

    func adopt(_ p: AVPlayer, video: VideoItem) {
        close()
        player = p
        self.video = video
        playing = p.rate != 0
        obs = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.4, preferredTimescale: 600),
                                        queue: .main) { [weak self] _ in
            self?.playing = (p.rate != 0)
        }
    }

    func toggle() {
        guard let p = player else { return }
        if p.rate != 0 { p.pause() } else { p.play() }
        playing = p.rate != 0
    }

    func close() {
        if let p = player {
            p.pause()
            if let o = obs { p.removeTimeObserver(o) }
        }
        obs = nil
        player = nil
        video = nil
        playing = false
    }
}

struct MiniPlayerView: View {
    @ObservedObject private var state = MiniPlayerState.shared
    var onExpand: (VideoItem) -> Void

    var body: some View {
        if let p = state.player, let v = state.video {
            ZStack(alignment: .bottomTrailing) {
                PreviewLayer(player: p)
                    .frame(width: 176, height: 100)
                    .background(Color.black)
                    .onTapGesture { onExpand(v) }
                HStack(spacing: 2) {
                    Button { state.toggle() } label: {
                        Image(systemName: state.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                            .frame(width: 30, height: 30)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    Button { state.close() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 30, height: 30)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(5)
            }
            .frame(width: 176, height: 100)
            .background(Color.black)
            .cornerRadius(12)
            .clipped()
            .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 4)
            .offset(state.offset)
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { g in
                        state.offset = CGSize(width: state.baseOffset.width + g.translation.width,
                                              height: state.baseOffset.height + g.translation.height)
                    }
                    .onEnded { _ in state.baseOffset = state.offset }
            )
        }
    }
}

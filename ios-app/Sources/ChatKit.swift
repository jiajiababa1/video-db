import SwiftUI
import AVFoundation
import AVKit
import CoreLocation
import PhotosUI
import UniformTypeIdentifiers

/// 聊天消息内容: 与网站 parseMsg 完全同构 (text / sticker / voice / loc),
/// img / video / file 为 App 增强 (网站端会降级显示为可点链接)。
enum MsgContent {
    case text(String)
    case sticker(String)
    case voice(String)
    case loc(name: String, lat: Double, lng: Double)
    case img(String)
    case video(String)
    case file(url: String, name: String, size: Int)

    static let stickers = ["😀","😂","🤣","😊","😍","😘","😎","🥳","😭","😡","😱","👍","👎","👏","🙏","💪","🤝","❤️","💔","🌹","🔥","🎉","🍺","💩","🤡","👻","🐱","🌚"]

    static func parse(_ raw: String) -> MsgContent {
        if raw.hasPrefix("{"), let data = raw.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let t = o["t"] as? String {
            func num(_ k: String) -> Double {
                if let n = o[k] as? NSNumber { return n.doubleValue }
                if let s = o[k] as? String { return Double(s) ?? 0 }
                return 0
            }
            switch t {
            case "sticker": return .sticker(o["v"] as? String ?? "🙂")
            case "voice": return .voice(o["v"] as? String ?? "")
            case "loc": return .loc(name: o["n"] as? String ?? "位置", lat: num("lat"), lng: num("lng"))
            case "img": return .img(o["v"] as? String ?? "")
            case "video": return .video(o["v"] as? String ?? "")
            case "file": return .file(url: o["v"] as? String ?? "", name: o["n"] as? String ?? "文件",
                                       size: (o["s"] as? NSNumber)?.intValue ?? 0)
            default: break
            }
        }
        return .text(raw)
    }

    var serialized: String {
        switch self {
        case .text(let s): return s
        case .sticker(let e): return json(["t": "sticker", "v": e])
        case .voice(let u): return json(["t": "voice", "v": u])
        case .loc(let n, let lat, let lng):
            return json(["t": "loc", "n": n, "lat": String(format: "%.6f", lat), "lng": String(format: "%.6f", lng)])
        case .img(let u): return json(["t": "img", "v": u])
        case .video(let u): return json(["t": "video", "v": u])
        case .file(let u, let n, let s): return json(["t": "file", "v": u, "n": n, "s": s])
        }
    }

    var preview: String {
        switch self {
        case .text(let s): return s
        case .sticker(let e): return e
        case .voice: return "[语音]"
        case .loc: return "[位置]"
        case .img: return "[图片]"
        case .video: return "[视频]"
        case .file(_, let n, _): return "[文件] " + n
        }
    }

    private func json(_ o: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: o),
              let s = String(data: d, encoding: .utf8) else { return "" }
        return s
    }
}

// MARK: - 语音播放
final class VoicePlayer: ObservableObject {
    @Published var playing = false
    private var player: AVPlayer?
    private var obs: NSObjectProtocol?

    func toggle(urlString: String) {
        if playing { player?.pause(); playing = false; return }
        guard let u = URL(string: urlString) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        let p = AVPlayer(url: u)
        player = p
        obs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { [weak self] _ in
            self?.playing = false
        }
        p.play()
        playing = true
    }
}

// MARK: - 消息气泡 (单聊/群聊共用)
struct MessageBubble: View {
    let content: MsgContent
    let isMe: Bool
    @StateObject private var voice = VoicePlayer()
    @State private var showImg = false
    @State private var showVideo: String? = nil

    var body: some View {
        Group {
            switch content {
            case .text(let s):
                Text(attributed(s))
                    .font(.system(size: 15))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(isMe ? Theme.gold.opacity(0.25) : Theme.surface2)
                    .cornerRadius(14)
            case .sticker(let e):
                Text(e).font(.system(size: 44))
            case .voice(let u):
                Button {
                    voice.toggle(urlString: u)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: voice.playing ? "pause.fill" : "play.fill")
                        Text(voice.playing ? "播放中…" : "语音消息")
                            .font(.system(size: 14))
                        Image(systemName: "waveform")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(isMe ? Theme.gold.opacity(0.25) : Theme.surface2)
                    .cornerRadius(14)
                    .foregroundColor(Theme.text)
                }
            case .loc(let n, let lat, let lng):
                Link(destination: URL(string: "http://maps.apple.com/?ll=\(lat),\(lng)&q=\(n.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!) {
                    HStack(spacing: 10) {
                        Text("📍").font(.system(size: 22))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(n).font(.system(size: 14, weight: .bold)).foregroundColor(Theme.text)
                            Text(String(format: "%.5f, %.5f", lat, lng))
                                .font(.caption2).foregroundColor(Theme.sub)
                            Text("点击打开地图").font(.caption2).foregroundColor(Theme.gold2)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(isMe ? Theme.gold.opacity(0.25) : Theme.surface2)
                    .cornerRadius(14)
                }
            case .img(let u):
                CachedImage(urlString: u)
                    .frame(width: 190, height: 140)
                    .cornerRadius(12)
                    .onTapGesture { showImg = true }
                    .sheet(isPresented: $showImg) {
                        ZStack {
                            Color.black.ignoresSafeArea()
                            CachedImage(urlString: u).scaledToFit()
                        }
                    }
            case .video(let u):
                ZStack {
                    Rectangle().fill(Color.black)
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44)).foregroundColor(.white.opacity(0.9))
                }
                .frame(width: 190, height: 140)
                .cornerRadius(12)
                .onTapGesture { showVideo = u }
                .sheet(item: Binding(get: { showVideo.map { IdentifiedString(value: $0) } },
                                     set: { showVideo = $0?.value })) { w in
                    SimpleVideoPlayer(urlString: w.value)
                }
            case .file(let u, let n, let s):
                Link(destination: URL(string: u) ?? URL(string: "about:blank")!) {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.fill").font(.system(size: 22)).foregroundColor(Theme.gold2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(n).font(.system(size: 13, weight: .bold)).foregroundColor(Theme.text).lineLimit(1)
                            Text(s > 0 ? ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file) : "点击下载")
                                .font(.caption2).foregroundColor(Theme.sub)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(isMe ? Theme.gold.opacity(0.25) : Theme.surface2)
                    .cornerRadius(14)
                }
            }
        }
    }

    private func attributed(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

struct IdentifiedString: Identifiable {
    let value: String
    var id: String { value }
}

/// 极简视频播放页 (作品/聊天视频共用)
struct SimpleVideoPlayer: View {
    let urlString: String
    @State private var player: AVPlayer?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let p = player {
                VideoPlayer(player: p).ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 28)).foregroundColor(.white.opacity(0.85))
                    }.padding()
                }
                Spacer()
            }
        }
        .onAppear {
            if let u = URL(string: urlString) {
                let p = AVPlayer(url: u)
                player = p
                p.play()
            }
        }
        .onDisappear { player?.pause() }
    }
}

// MARK: - 录音
final class VoiceRecorder: ObservableObject {
    @Published var recording = false
    @Published var seconds = 0
    private var rec: AVAudioRecorder?
    private var timer: Timer?
    private var fileURL: URL?

    func start() {
        AVAudioSession.sharedInstance().requestRecordPermission { ok in
            guard ok else { return }
            DispatchQueue.main.async { self.begin() }
        }
    }

    private func begin() {
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                                       AVSampleRateKey: 44100,
                                       AVNumberOfChannelsKey: 1,
                                       AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
        rec = try? AVAudioRecorder(url: url, settings: settings)
        fileURL = url
        rec?.record()
        recording = true
        seconds = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.seconds += 1
        }
    }

    func stop() -> URL? {
        rec?.stop()
        rec = nil
        timer?.invalidate()
        recording = false
        return fileURL
    }
}

// MARK: - 一次性定位
final class LocationFetcher: NSObject, CLLocationManagerDelegate {
    private let mgr = CLLocationManager()
    private var cont: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        mgr.delegate = self
    }

    func fetch() async -> CLLocation? {
        await withCheckedContinuation { c in
            cont = c
            mgr.requestWhenInUseAuthorization()
            mgr.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        cont?.resume(returning: locations.last)
        cont = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        cont?.resume(returning: nil)
        cont = nil
    }
}

// MARK: - 相册选择 (图片/视频)
struct MediaPicker: UIViewControllerRepresentable {
    var onPick: (_ tempURL: URL, _ isVideo: Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration()
        cfg.filter = .any(of: [.images, .videos])
        cfg.selectionLimit = 1
        let vc = PHPickerViewController(configuration: cfg)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: MediaPicker
        init(_ p: MediaPicker) { parent = p }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard let item = results.first?.itemProvider else { return }
            let isVideo = item.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
            let type = isVideo ? UTType.movie.identifier : UTType.image.identifier
            item.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url = url else { return }
                let ext = url.pathExtension.isEmpty ? (isVideo ? "mov" : "jpg") : url.pathExtension
                let dst = FileManager.default.temporaryDirectory
                    .appendingPathComponent("pick-\(UUID().uuidString).\(ext)")
                try? FileManager.default.copyItem(at: url, to: dst)
                DispatchQueue.main.async { self.parent.onPick(dst, isVideo) }
            }
        }
    }
}

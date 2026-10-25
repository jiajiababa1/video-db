import Foundation
import SwiftUI

/// 离线下载: 把已解析的直链视频下到本机, 断网也能看。
struct DownloadRecord: Codable, Identifiable {
    var video: VideoItem
    var fileName: String
    var size: Int64
    var at: TimeInterval
    var id: String { video.video_id }
}

final class Downloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = Downloader()

    @Published var progresses: [String: Double] = [:]
    @Published var records: [DownloadRecord] = []

    private var session: URLSession!
    private var pending: [Int: VideoItem] = [:]

    private var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private var indexURL: URL { dir.appendingPathComponent("records.json") }

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        if let data = try? Data(contentsOf: indexURL),
           let rows = try? JSONDecoder().decode([DownloadRecord].self, from: data) {
            records = rows
        }
    }

    func isDownloaded(_ id: String) -> Bool { records.contains { $0.id == id } }

    func localURL(for id: String) -> URL? {
        guard let r = records.first(where: { $0.id == id }) else { return nil }
        let u = dir.appendingPathComponent(r.fileName)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func enqueue(_ v: VideoItem, url: URL) {
        guard !isDownloaded(v.video_id), progresses[v.video_id] == nil else { return }
        // m3u8 是流媒体清单, 不能当文件下 (hsex 等)
        if url.pathExtension.lowercased() == "m3u8" { return }
        let task = session.downloadTask(with: url)
        pending[task.taskIdentifier] = v
        DispatchQueue.main.async { self.progresses[v.video_id] = 0.001 }
        task.resume()
    }

    func delete(_ r: DownloadRecord) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(r.fileName))
        records.removeAll { $0.id == r.id }
        persist()
    }

    var totalSize: Int64 { records.reduce(0) { $0 + $1.size } }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    // MARK: URLSessionDownloadDelegate
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let v = pending[downloadTask.taskIdentifier], totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.progresses[v.video_id] = p }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let v = pending.removeValue(forKey: downloadTask.taskIdentifier) else { return }
        let ext = downloadTask.response?.url?.pathExtension.isEmpty == false
            ? (downloadTask.response!.url!.pathExtension) : "mp4"
        let name = v.video_id + "." + ext
        let dst = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dst)
        var size: Int64 = 0
        do {
            try FileManager.default.moveItem(at: location, to: dst)
            size = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int64) ?? 0
            let rec = DownloadRecord(video: v, fileName: name, size: size,
                                     at: Date().timeIntervalSince1970)
            DispatchQueue.main.async {
                self.records.insert(rec, at: 0)
                self.progresses[v.video_id] = nil
                self.persist()
            }
        } catch {
            DispatchQueue.main.async { self.progresses[v.video_id] = nil }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let v = pending.removeValue(forKey: task.taskIdentifier) else { return }
        if error != nil {
            DispatchQueue.main.async { self.progresses[v.video_id] = nil }
        }
    }
}

/// 离线下载页
struct DownloadsView: View {
    var embedded: Bool = false
    @ObservedObject private var dl = Downloader.shared
    @State private var playFile: IdentifiedString? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if !dl.progresses.isEmpty {
                    ForEach(Array(dl.progresses.keys.sorted()), id: \.self) { id in
                        HStack(spacing: 10) {
                            ProgressView().tint(Theme.gold)
                            Text("下载中 \(id)")
                                .font(.caption).foregroundColor(Theme.sub).lineLimit(1)
                            ProgressView(value: dl.progresses[id] ?? 0).tint(Theme.gold)
                        }
                        .padding(12).background(Theme.surface).cornerRadius(12)
                    }
                }
                if dl.records.isEmpty && dl.progresses.isEmpty {
                    Text("还没有下载的视频\n在播放页点「⬇ 下载」即可存到手机里离线看")
                        .multilineTextAlignment(.center)
                        .foregroundColor(Theme.sub).padding(.top, 60)
                }
                if !dl.records.isEmpty {
                    Text("共 \(dl.records.count) 个 · 占用 " + ByteCountFormatter.string(fromByteCount: dl.totalSize, countStyle: .file))
                        .font(.caption).foregroundColor(Theme.sub)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(dl.records) { r in
                    HStack(spacing: 11) {
                        CachedImage(urlString: r.video.thumbnail_url)
                            .frame(width: 110)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipped().cornerRadius(9)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.video.displayTitle)
                                .font(.system(size: 13.5)).lineLimit(2)
                            Text(ByteCountFormatter.string(fromByteCount: r.size, countStyle: .file))
                                .font(.caption).foregroundColor(Theme.sub)
                            HStack(spacing: 12) {
                                Button("▶ 播放") {
                                    if let u = dl.localURL(for: r.id) {
                                        playFile = IdentifiedString(value: u.absoluteString)
                                    }
                                }
                                .font(.caption.weight(.bold)).foregroundColor(Theme.gold2)
                                Button("删除", role: .destructive) { dl.delete(r) }
                                    .font(.caption).foregroundColor(.red.opacity(0.8))
                            }
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Theme.surface)
                    .cornerRadius(14)
                }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(embedded ? "" : "离线下载")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $playFile) { w in
            SimpleVideoPlayer(urlString: w.value)
        }
    }
}

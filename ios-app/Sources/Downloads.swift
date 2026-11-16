import Foundation
import SwiftUI
import AVFoundation

/// 离线下载: 把已解析的直链视频下到本机, 断网也能看。
/// v5.0: ① m3u8 走 AVAssetDownloadTask 原生 HLS 离线下载 (下成 .movpkg 本地包);
/// ② 下载队列: 最多同时 2 个, 其余排队; 失败可重试, 进行中可取消 (学 Seal 的下载管理)。
struct DownloadRecord: Codable, Identifiable {
    var video: VideoItem
    var fileName: String
    var size: Int64
    var at: TimeInterval
    var id: String { video.video_id }
}

final class Downloader: NSObject, ObservableObject, URLSessionDownloadDelegate, AVAssetDownloadDelegate {
    static let shared = Downloader()

    @Published var progresses: [String: Double] = [:]   // 正在下载: video_id -> 0...1
    @Published var notes: [String: String] = [:]        // 排队中 / 失败原因: video_id -> 文案
    @Published var records: [DownloadRecord] = []

    private var session: URLSession!
    private var hlsSession: AVAssetDownloadURLSession!
    private var pending: [Int: VideoItem] = [:]        // 文件任务 taskIdentifier -> 视频
    private var hlsPending: [Int: VideoItem] = [:]     // HLS 任务 taskIdentifier -> 视频
    private var fileTasks: [String: URLSessionDownloadTask] = [:]
    private var hlsTasks: [String: AVAssetDownloadTask] = [:]
    private var attempts: [String: (video: VideoItem, url: URL, hls: Bool)] = [:]
    private var queue: [(video: VideoItem, url: URL, hls: Bool)] = []

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
        // 注意: AVAssetDownloadURLSession 只接受后台配置, 用 .default 会直接抛异常崩溃 (v5.1 实测)
        hlsSession = AVAssetDownloadURLSession(configuration: .background(withIdentifier: "com.jiajiababa1.videodb.hlsdl"),
                                               assetDownloadDelegate: self, delegateQueue: .main)
        if let data = try? Data(contentsOf: indexURL),
           let rows = try? JSONDecoder().decode([DownloadRecord].self, from: data) {
            records = rows
        }
    }

    func isDownloaded(_ id: String) -> Bool { records.contains { $0.id == id } }
    func isBusy(_ id: String) -> Bool {
        progresses[id] != nil || notes[id] != nil
    }
    func attemptVideo(_ id: String) -> VideoItem? { attempts[id]?.video }

    /// 下载文件夹 (Documents/downloads), 供「打开文件夹」跳转系统文件 App
    var folderURL: URL { dir }

    func localURL(for id: String) -> URL? {
        guard let r = records.first(where: { $0.id == id }) else { return nil }
        let u = dir.appendingPathComponent(r.fileName)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// 统一入口: mp4 等直链走文件下载, m3u8 走 HLS 离线下载; 超过并发上限自动排队
    func enqueue(_ v: VideoItem, url: URL) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.enqueue(v, url: url) }
            return
        }
        guard !isDownloaded(v.video_id), !isBusy(v.video_id) else { return }
        let hls = url.pathExtension.lowercased() == "m3u8"
        attempts[v.video_id] = (v, url, hls)
        queue.append((v, url, hls))
        notes[v.video_id] = "排队中…"
        pump()
    }

    func cancel(_ id: String) {
        queue.removeAll { $0.video.video_id == id }
        fileTasks[id]?.cancel()
        hlsTasks[id]?.cancel()
        fileTasks[id] = nil
        hlsTasks[id] = nil
        DispatchQueue.main.async {
            self.progresses[id] = nil
            self.notes[id] = nil
        }
    }

    func retry(_ id: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.retry(id) }
            return
        }
        guard let a = attempts[id] else { return }
        notes[id] = nil   // 必须同步清掉, 不然 enqueue 的 isBusy 守卫会把重试挡回去
        enqueue(a.video, url: a.url)
    }

    func clearFailed(_ id: String) {
        DispatchQueue.main.async {
            self.notes[id] = nil
            self.progresses[id] = nil
        }
    }

    private func pump() {
        while pending.count + hlsPending.count < 2, !queue.isEmpty {
            let job = queue.removeFirst()
            DispatchQueue.main.async { self.notes[job.video.video_id] = nil }
            if job.hls { startHLS(job.video, url: job.url) } else { startFile(job.video, url: job.url) }
        }
    }

    private func startFile(_ v: VideoItem, url: URL) {
        let task = session.downloadTask(with: url)
        pending[task.taskIdentifier] = v
        fileTasks[v.video_id] = task
        DispatchQueue.main.async { self.progresses[v.video_id] = 0.001 }
        task.resume()
    }

    private func startHLS(_ v: VideoItem, url: URL) {
        let asset = AVURLAsset(url: url)
        guard let task = hlsSession.makeAssetDownloadTask(asset: asset, assetTitle: v.displayTitle,
                                                          assetArtworkData: nil, options: nil) else {
            failHLS(v, reason: "无法创建下载任务")
            return
        }
        hlsPending[task.taskIdentifier] = v
        hlsTasks[v.video_id] = task
        DispatchQueue.main.async { self.progresses[v.video_id] = 0.001 }
        task.resume()
    }

    private func failHLS(_ v: VideoItem, reason: String) {
        DispatchQueue.main.async {
            self.progresses[v.video_id] = nil
            self.notes[v.video_id] = "下载失败: " + reason
            self.pump()
        }
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

    private func dirSize(_ url: URL) -> Int64 {
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: URLSessionDownloadDelegate (文件下载)
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
        fileTasks[v.video_id] = nil
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
                self.pump()
            }
        } catch {
            DispatchQueue.main.async {
                self.progresses[v.video_id] = nil
                self.notes[v.video_id] = "下载失败: 保存文件出错"
                self.pump()
            }
        }
    }

    // MARK: AVAssetDownloadDelegate (HLS 离线下载)
    @objc func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                    totalTimeRangesExpectedToLoad: [NSValue]) {
        guard let v = hlsPending[assetDownloadTask.taskIdentifier] else { return }
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        let total = totalTimeRangesExpectedToLoad.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        guard total > 0 else { return }
        DispatchQueue.main.async { self.progresses[v.video_id] = min(0.999, loaded / total) }
    }

    @objc func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let v = hlsPending.removeValue(forKey: assetDownloadTask.taskIdentifier) else { return }
        hlsTasks[v.video_id] = nil
        let name = v.video_id + ".movpkg"
        let dst = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dst)
        do {
            try FileManager.default.moveItem(at: location, to: dst)
            let rec = DownloadRecord(video: v, fileName: name, size: dirSize(dst),
                                     at: Date().timeIntervalSince1970)
            DispatchQueue.main.async {
                self.records.insert(rec, at: 0)
                self.progresses[v.video_id] = nil
                self.persist()
                self.pump()
            }
        } catch {
            failHLS(v, reason: "保存文件出错")
        }
    }

    /// 后台会话事件处理完 (系统因后台下载唤醒 App 时会调; 无事可做, 实现它让系统知道已处理)
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {}

    // MARK: 任务结束 (两个会话共用)
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let cancelled = (error as NSError?)?.code == NSURLErrorCancelled
        if let v = pending.removeValue(forKey: task.taskIdentifier) {
            fileTasks[v.video_id] = nil
            if cancelled {
                DispatchQueue.main.async { self.pump() }
                return
            }
            if let error = error {
                DispatchQueue.main.async {
                    self.progresses[v.video_id] = nil
                    self.notes[v.video_id] = "下载失败: " + error.localizedDescription
                    self.pump()
                }
            }
            return
        }
        if let v = hlsPending.removeValue(forKey: task.taskIdentifier) {
            hlsTasks[v.video_id] = nil
            if cancelled {
                DispatchQueue.main.async { self.pump() }
                return
            }
            if let error = error {
                failHLS(v, reason: error.localizedDescription)
            }
            return
        }
    }
}


/// 离线下载页 (v5.0: 队列/失败/完成分区 + 批量下载收藏)
struct DownloadsView: View {
    var embedded: Bool = false
    @ObservedObject private var dl = Downloader.shared
    @EnvironmentObject var library: Library
    @State private var playFile: IdentifiedString? = nil
    @State private var batchNote = ""
    @State private var shareFile: IdentifiedString? = nil

    /// 在系统「文件」App 里打开下载文件夹 (shareddocuments 深链到本 App 的 Documents/downloads)
    private func openFolder() {
        let path = dl.folderURL.path
        if let url = URL(string: "shareddocuments://" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)) {
            UIApplication.shared.open(url)
        }
    }

    private var activeIds: [String] {
        Array(Set(dl.progresses.keys).union(dl.notes.keys)).sorted()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                batchBar
                ForEach(activeIds, id: \.self) { id in
                    activeRow(id)
                }
                if dl.records.isEmpty && activeIds.isEmpty {
                    Text("还没有下载的视频\n在播放页点「⬇ 下载」即可存到手机里离线看\n(m3u8 流媒体现在也能下了)")
                        .multilineTextAlignment(.center)
                        .foregroundColor(Theme.sub).padding(.top, 60)
                }
                if !dl.records.isEmpty {
                    HStack {
                        Text("共 \(dl.records.count) 个 · 占用 " + ByteCountFormatter.string(fromByteCount: dl.totalSize, countStyle: .file))
                            .font(.caption).foregroundColor(Theme.sub)
                        Spacer()
                        Button {
                            openFolder()
                        } label: {
                            Label("打开文件夹", systemImage: "folder")
                                .font(.caption.weight(.bold)).foregroundColor(Theme.gold2)
                        }
                        .buttonStyle(.plain)
                    }
                }
                ForEach(dl.records) { r in
                    recordRow(r)
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
        .sheet(item: $shareFile) { w in
            if let u = URL(string: w.value) {
                ActivityView(items: [u])
            }
        }
    }

    private var batchBar: some View {
        let todo = library.favorites.compactMap { library.snapshots[$0] }
            .filter { !dl.isDownloaded($0.video_id) && !dl.isBusy($0.video_id) && $0.storedURL != nil }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    for v in todo {
                        if let u = v.storedURL { dl.enqueue(v, url: u) }
                    }
                    batchNote = todo.isEmpty ? "收藏里没有可批量下载的新视频" : "已加入队列 \(todo.count) 个（同时下 2 个，其余排队）"
                } label: {
                    Label("批量下载收藏", systemImage: "arrow.down.doc")
                        .font(.system(size: 13.5, weight: .bold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.surface2).foregroundColor(Theme.text)
                        .cornerRadius(99)
                }
                .buttonStyle(.plain)
                Text("可下 \(todo.count) 个")
                    .font(.caption).foregroundColor(Theme.sub)
                Spacer()
            }
            if !batchNote.isEmpty {
                Text(batchNote).font(.caption2).foregroundColor(Theme.gold2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activeRow(_ id: String) -> some View {
        let v = dl.attemptVideo(id)
        let failed = (dl.notes[id] ?? "").hasPrefix("下载失败")
        return HStack(spacing: 10) {
            if let p = dl.progresses[id] {
                ProgressView(value: p).tint(Theme.gold).frame(width: 90)
                Text("下载中 \(Int(p * 100))%")
                    .font(.caption).foregroundColor(Theme.sub)
            } else if failed {
                Image(systemName: "exclamationmark.triangle").foregroundColor(.red)
                Text(dl.notes[id] ?? "")
                    .font(.caption).foregroundColor(.red).lineLimit(2)
            } else {
                ProgressView().tint(Theme.gold)
                Text(dl.notes[id] ?? "排队中…")
                    .font(.caption).foregroundColor(Theme.sub)
            }
            Text(v?.displayTitle ?? id)
                .font(.caption).lineLimit(1)
            Spacer()
            if dl.progresses[id] != nil || !failed && dl.notes[id] != nil {
                Button("取消") { dl.cancel(id) }
                    .font(.caption).foregroundColor(Theme.sub)
            }
            if failed {
                Button("重试") { dl.retry(id) }
                    .font(.caption.weight(.bold)).foregroundColor(Theme.gold2)
                Button("清除") { dl.clearFailed(id) }
                    .font(.caption).foregroundColor(Theme.sub)
            }
        }
        .padding(12).glassPanel(12)
    }

    private func recordRow(_ r: DownloadRecord) -> some View {
        HStack(spacing: 11) {
            CachedImage(urlString: r.video.thumbnail_url)
                .frame(width: 110)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipped().cornerRadius(9)
            VStack(alignment: .leading, spacing: 4) {
                Text(r.video.displayTitle)
                    .font(.system(size: 13.5)).lineLimit(2)
                Text(ByteCountFormatter.string(fromByteCount: r.size, countStyle: .file)
                     + (r.fileName.hasSuffix(".movpkg") ? " · HLS 离线包" : ""))
                    .font(.caption).foregroundColor(Theme.sub)
                HStack(spacing: 12) {
                    Button("▶ 播放") {
                        if let u = dl.localURL(for: r.id) {
                            playFile = IdentifiedString(value: u.absoluteString)
                        }
                    }
                    .font(.caption.weight(.bold)).foregroundColor(Theme.gold2)
                    Button("导出") {
                        if let u = dl.localURL(for: r.id) {
                            shareFile = IdentifiedString(value: u.absoluteString)
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
        .glassPanel(14)
    }
}

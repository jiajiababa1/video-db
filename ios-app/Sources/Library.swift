import Foundation
import Combine

/// 本机片库: 收藏 / 稍后看 / 历史 / 关注 / 屏蔽 (与网站 localStorage 同构, JSON 落盘)
final class Library: ObservableObject {
    @Published var favorites: [String] = []            // video_id, 新在前
    @Published var watchLater: [String] = []
    @Published var history: [String] = []              // 看过的 video_id, 新在前
    @Published var progress: [String: Double] = [:]    // video_id -> 0...1
    @Published var follows: [String] = []              // 作者名
    @Published var blockedAuthors: [String] = []
    @Published var snapshots: [String: VideoItem] = [:] // 历史/收藏条目的视频快照 (离线展示用)

    private let fileURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("library.json")
        load()
    }

    // MARK: - 查询
    func isFav(_ id: String) -> Bool { favorites.contains(id) }
    func isWatchLater(_ id: String) -> Bool { watchLater.contains(id) }
    func isFollowing(_ author: String) -> Bool { follows.contains(author) }

    // MARK: - 变更
    func toggleFav(_ v: VideoItem) {
        if isFav(v.video_id) { favorites.removeAll { $0 == v.video_id } }
        else { favorites.insert(v.video_id, at: 0); snapshots[v.video_id] = v }
        save()
    }

    func toggleWatchLater(_ v: VideoItem) {
        if isWatchLater(v.video_id) { watchLater.removeAll { $0 == v.video_id } }
        else { watchLater.insert(v.video_id, at: 0); snapshots[v.video_id] = v }
        save()
    }

    func toggleFollow(_ author: String) {
        guard !author.isEmpty else { return }
        if isFollowing(author) { follows.removeAll { $0 == author } }
        else { follows.insert(author, at: 0) }
        save()
    }

    func recordWatch(_ v: VideoItem, progress p: Double? = nil) {
        history.removeAll { $0 == v.video_id }
        history.insert(v.video_id, at: 0)
        if history.count > 500 { history = Array(history.prefix(500)) }
        snapshots[v.video_id] = v
        if let p = p { progress[v.video_id] = min(max(p, 0), 1) }
        save()
    }

    func isBlocked(_ author: String) -> Bool { blockedAuthors.contains(author) }

    func toggleBlock(_ author: String) {
        guard !author.isEmpty else { return }
        if isBlocked(author) { blockedAuthors.removeAll { $0 == author } }
        else { blockedAuthors.append(author) }
        save()
    }

    func clearHistory() { history.removeAll(); progress.removeAll(); save() }
    func clearAll() {
        favorites.removeAll(); watchLater.removeAll(); history.removeAll()
        progress.removeAll(); follows.removeAll(); save()
    }

    // MARK: - 持久化
    private struct Persist: Codable {
        var favorites: [String] = []
        var watchLater: [String] = []
        var history: [String] = []
        var progress: [String: Double] = [:]
        var follows: [String] = []
        var blockedAuthors: [String] = []
        var snapshots: [String: VideoItem] = [:]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let p = try? JSONDecoder().decode(Persist.self, from: data) else { return }
        favorites = p.favorites; watchLater = p.watchLater; history = p.history
        progress = p.progress; follows = p.follows; blockedAuthors = p.blockedAuthors
        snapshots = p.snapshots
    }

    private func save() {
        let p = Persist(favorites: favorites, watchLater: watchLater, history: history,
                        progress: progress, follows: follows, blockedAuthors: blockedAuthors,
                        snapshots: snapshots)
        if let data = try? JSONEncoder().encode(p) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

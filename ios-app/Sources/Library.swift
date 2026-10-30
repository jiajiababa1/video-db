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
    // v1.3 与网站对齐的账号数据 (经 cloud_user_config 同步)
    @Published var favFolders: [String: [String]] = [:]  // 收藏分组: 名 -> [video_id]
    @Published var hiddenIds: [String] = []              // 隐藏的视频
    @Published var badwords: [String] = []               // 屏蔽词 (标题命中即过滤)
    @Published var searchRecent: [String] = []           // 搜索历史 (最近 12)
    @Published var recycle: [RecycleEntry] = []          // 回收站
    @Published var countedViews: [String] = []           // 已计过观看数的 "账号|video_id" (同一人只计一次)

    /// 任一变更后回调 (RootView 挂 ConfigSync 推送)
    var onMutate: (() -> Void)?

    struct RecycleEntry: Codable, Identifiable {
        var item: VideoItem
        var kind: String   // fav / hist / wl
        var at: TimeInterval
        var id: String { item.video_id + "|" + kind }
    }

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
        if isFav(v.video_id) { favorites.removeAll { $0 == v.video_id }; Haptics.light() }
        else { favorites.insert(v.video_id, at: 0); snapshots[v.video_id] = v; Haptics.success() }
        save()
    }

    func toggleWatchLater(_ v: VideoItem) {
        if isWatchLater(v.video_id) { watchLater.removeAll { $0 == v.video_id }; Haptics.light() }
        else { watchLater.insert(v.video_id, at: 0); snapshots[v.video_id] = v; Haptics.success() }
        save()
    }

    func toggleFollow(_ author: String) {
        guard !author.isEmpty else { return }
        if isFollowing(author) { follows.removeAll { $0 == author }; Haptics.light() }
        else { follows.insert(author, at: 0); Haptics.success() }
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
        Haptics.light()
        save()
    }

    // MARK: - 收藏分组 / 隐藏 / 屏蔽词 / 搜索历史 / 回收站
    func createFolder(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, favFolders[n] == nil else { return }
        favFolders[n] = []
        save()
    }

    func deleteFolder(_ name: String) { favFolders[name] = nil; save() }

    func toggleInFolder(_ folder: String, _ v: VideoItem) {
        var ids = favFolders[folder] ?? []
        if ids.contains(v.video_id) { ids.removeAll { $0 == v.video_id } }
        else { ids.insert(v.video_id, at: 0); snapshots[v.video_id] = v; if !isFav(v.video_id) { favorites.insert(v.video_id, at: 0) } }
        favFolders[folder] = ids
        save()
    }

    func isHidden(_ id: String) -> Bool { hiddenIds.contains(id) }

    func toggleHidden(_ v: VideoItem) {
        if isHidden(v.video_id) { hiddenIds.removeAll { $0 == v.video_id } }
        else { hiddenIds.append(v.video_id); snapshots[v.video_id] = v }
        save()
    }

    func addBadword(_ w: String) {
        let t = w.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !badwords.contains(t) else { return }
        badwords.append(t); save()
    }

    func removeBadword(_ w: String) { badwords.removeAll { $0 == w }; save() }

    func titleBlocked(_ title: String?) -> Bool {
        guard let t = title, !badwords.isEmpty else { return false }
        return badwords.contains { t.localizedCaseInsensitiveContains($0) }
    }

    func pushSearchRecent(_ q: String) {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        searchRecent.removeAll { $0 == t }
        searchRecent.insert(t, at: 0)
        searchRecent = Array(searchRecent.prefix(12))
        save()
    }

    func clearSearchRecent() { searchRecent.removeAll(); save() }

    func recycleFav(_ v: VideoItem) {
        favorites.removeAll { $0 == v.video_id }
        recycle.insert(RecycleEntry(item: v, kind: "fav", at: Date().timeIntervalSince1970), at: 0)
        save()
    }

    func recycleHistoryItem(_ v: VideoItem) {
        history.removeAll { $0 == v.video_id }
        recycle.insert(RecycleEntry(item: v, kind: "hist", at: Date().timeIntervalSince1970), at: 0)
        save()
    }

    func restoreRecycle(_ e: RecycleEntry) {
        recycle.removeAll { $0.id == e.id }
        snapshots[e.item.video_id] = e.item
        switch e.kind {
        case "fav": if !isFav(e.item.video_id) { favorites.insert(e.item.video_id, at: 0) }
        case "wl": if !isWatchLater(e.item.video_id) { watchLater.insert(e.item.video_id, at: 0) }
        default: if !history.contains(e.item.video_id) { history.insert(e.item.video_id, at: 0) }
        }
        save()
    }

    func purgeRecycle() { recycle.removeAll(); save() }

    func clearHistory() {
        for id in history { if let v = snapshots[id] { recycle.insert(RecycleEntry(item: v, kind: "hist", at: Date().timeIntervalSince1970), at: 0) } }
        history.removeAll(); progress.removeAll(); save()
    }
    func clearAll() {
        favorites.removeAll(); watchLater.removeAll(); history.removeAll()
        progress.removeAll(); follows.removeAll(); save()
    }

    /// 供云同步在批量套用远端值后落盘
    func persistNow() { save() }

    // MARK: - 观看计数去重
    func markCounted(_ key: String) {
        if !countedViews.contains(key) { countedViews.append(key); save() }
    }

    func unmarkCounted(_ key: String) {
        countedViews.removeAll { $0 == key }
        save()
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
        var favFolders: [String: [String]] = [:]
        var hiddenIds: [String] = []
        var badwords: [String] = []
        var searchRecent: [String] = []
        var recycle: [RecycleEntry] = []
        var countedViews: [String] = []
    }

    private struct PersistV1: Codable {
        var favorites: [String] = []
        var watchLater: [String] = []
        var history: [String] = []
        var progress: [String: Double] = [:]
        var follows: [String] = []
        var blockedAuthors: [String] = []
        var snapshots: [String: VideoItem] = [:]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let p = try? JSONDecoder().decode(Persist.self, from: data) {
            favorites = p.favorites; watchLater = p.watchLater; history = p.history
            progress = p.progress; follows = p.follows; blockedAuthors = p.blockedAuthors
            snapshots = p.snapshots; favFolders = p.favFolders; hiddenIds = p.hiddenIds
            badwords = p.badwords; searchRecent = p.searchRecent; recycle = p.recycle
            countedViews = p.countedViews
            return
        }
        if let p = try? JSONDecoder().decode(PersistV1.self, from: data) {
            favorites = p.favorites; watchLater = p.watchLater; history = p.history
            progress = p.progress; follows = p.follows; blockedAuthors = p.blockedAuthors
            snapshots = p.snapshots
        }
    }

    private func save() {
        let p = Persist(favorites: favorites, watchLater: watchLater, history: history,
                        progress: progress, follows: follows, blockedAuthors: blockedAuthors,
                        snapshots: snapshots, favFolders: favFolders, hiddenIds: hiddenIds,
                        badwords: badwords, searchRecent: searchRecent, recycle: recycle,
                        countedViews: countedViews)
        if let data = try? JSONEncoder().encode(p) {
            try? data.write(to: fileURL, options: .atomic)
        }
        onMutate?()
    }
}

import Foundation

/// 视频流首页缓存 (落盘): 打开页面先显缓存内容, 再后台刷新替换, 不再每次白屏拉库
enum FeedCache {
    struct Entry: Codable {
        var items: [VideoItem]
        var total: Int?
        var savedAt: Double
    }

    private static var dir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let u = docs.appendingPathComponent("feedcache")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func key(section: AppSection?, author: String?, search: String?,
                    personal: Bool, playableOnly: Bool, hot: Bool) -> String {
        ["s=\(section?.id ?? "")",
         "a=\(author ?? "")",
         "q=\(search ?? "")",
         "p=\(personal ? 1 : 0)",
         "pl=\(playableOnly ? 1 : 0)",
         "h=\(hot ? 1 : 0)"].joined(separator: "|")
    }

    static func homeKey(_ shelf: String) -> String { "home|" + shelf }

    static func read(_ key: String) -> Entry? {
        let f = dir.appendingPathComponent(safeName(key))
        guard let data = try? Data(contentsOf: f) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    static func write(_ key: String, items: [VideoItem], total: Int?) {
        let e = Entry(items: items, total: total, savedAt: Date().timeIntervalSince1970)
        let f = dir.appendingPathComponent(safeName(key))
        if let data = try? JSONEncoder().encode(e) {
            try? data.write(to: f, options: .atomic)
        }
    }

    private static func safeName(_ key: String) -> String {
        var h: UInt64 = 5381
        for b in key.utf8 { h = (h &* 33) &+ UInt64(b) }
        return "fc-\(h).json"
    }
}

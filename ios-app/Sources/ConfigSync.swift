import Foundation

/// 账号配置云同步 (cloud_user_config): 关注作者/屏蔽作者/收藏分组/隐藏/屏蔽词/搜索历史/播放进度。
/// 与网站 _curConfig / cloudPullConfig 同构 — 推送时先读云端现值合并, 只覆盖本 App 管理的键,
/// 网站自己的字段 (prefs/ext 其他项/联动密钥等) 原样保留。
enum ConfigSync {
    private static var pending: Task<Void, Never>?
    private(set) static var applyingRemote = false

    static func schedulePush(session: Session, library: Library) {
        guard session.isLoggedIn, !applyingRemote else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { await push(session: session, library: library) }
        }
    }

    private static func fetchData(user: String) async -> [String: Any]? {
        let urlStr = SB.base.absoluteString + "/rest/v1/cloud_user_config?username=eq."
            + (user.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? user)
            + "&select=data&limit=1"
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        for (k, v) in SB.headers() { req.setValue(v, forHTTPHeaderField: k) }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = rows.first else { return nil }
        return first["data"] as? [String: Any]
    }

    static func pull(session: Session, library: Library) async {
        guard session.isLoggedIn, let user = session.username else { return }
        guard let data = await fetchData(user: user) else { return }
        applyingRemote = true
        await MainActor.run {
            if let arr = data["blockedAuthors"] as? [String] { library.blockedAuthors = arr }
            if let arr = data["followedAuthors"] as? [String] { library.follows = arr }
            let ext = data["ext"] as? [String: Any] ?? [:]
            if let f = ext["fav_folders"] as? [String: [String]] { library.favFolders = f }
            if let h = ext["vid_hidden"] as? [String] { library.hiddenIds = h }
            if let b = ext["vid_badwords"] as? [String] { library.badwords = b }
            if let r = ext["ss_recent"] as? [String] { library.searchRecent = Array(r.prefix(12)) }
            if let prog = ext["vid_progress"] as? [String: Any] {
                for (id, v) in prog {
                    guard let sec = (v as? NSNumber)?.doubleValue,
                          let item = library.snapshots[id],
                          let dur = parseDuration(item.duration), dur > 0 else { continue }
                    library.progress[id] = min(max(sec / dur, 0), 1)
                }
            }
            library.persistNow()
        }
        applyingRemote = false
    }

    static func push(session: Session, library: Library) async {
        guard session.isLoggedIn, let user = session.username, !applyingRemote else { return }
        var data = await fetchData(user: user) ?? [:]
        data["blockedAuthors"] = library.blockedAuthors
        data["followedAuthors"] = library.follows
        var ext = data["ext"] as? [String: Any] ?? [:]
        ext["fav_folders"] = library.favFolders
        ext["vid_hidden"] = library.hiddenIds
        ext["vid_badwords"] = library.badwords
        ext["ss_recent"] = Array(library.searchRecent.prefix(12))
        var prog: [String: Double] = [:]
        for (id, frac) in library.progress {
            if prog.count >= 100 { break }
            if let item = library.snapshots[id], let dur = parseDuration(item.duration), dur > 0 {
                prog[id] = (frac * dur * 10).rounded() / 10
            }
        }
        ext["vid_progress"] = prog
        data["ext"] = ext
        let body: [String: Any] = [
            "username": user,
            "data": data,
            "updated_at": ISO8601DateFormatter().string(from: Date()),
        ]
        try? await SB.insert("rest/v1/cloud_user_config", body: body,
                             prefer: "resolution=merge-duplicates,return=minimal")
    }

    /// "12:34" / "1:02:03" / "95" -> 秒; 时长列存的是播放链接时返回 nil
    static func parseDuration(_ s: String?) -> Double? {
        guard let s = s, !s.contains("://"), !s.isEmpty else { return nil }
        let parts = s.split(separator: ":")
        var total = 0.0
        for p in parts {
            guard let v = Double(p) else { return nil }
            total = total * 60 + v
        }
        return total > 0 ? total : nil
    }
}

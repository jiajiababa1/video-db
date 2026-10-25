import Foundation

/// 云同步: cloud_user_data 的 hist/fav/wl 三类 (合并规则与网站 cloudSyncAll 一致的简化版)
enum CloudSync {
    struct Row: Codable {
        var kind: String
        var video_id: String
        var watched_at: String?
    }

    static let caps = ["hist": 200, "fav": 500, "wl": 200]

    /// 拉取并合并到本地片库 (云端在前、本地独有补后、截断上限), 再把本地独有的补传
    static func pullMerge(into lib: Library, session: Session) async {
        guard session.isLoggedIn, let user = session.username else { return }
        let url = SB.base.absoluteString + "/rest/v1/cloud_user_data?username=eq."
            + (user.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? user)
            + "&select=kind,video_id,watched_at&order=watched_at.desc&limit=1000"
        let (rows, _): ([Row], Int?) = (try? await SB.getRaw(url)) ?? ([], nil)
        let cloud: [String: [String]] = [
            "hist": rows.filter { $0.kind == "hist" }.map { $0.video_id },
            "fav": rows.filter { $0.kind == "fav" }.map { $0.video_id },
            "wl": rows.filter { $0.kind == "wl" }.map { $0.video_id },
        ]
        func merged(_ kind: String, _ local: [String]) -> [String] {
            var out = cloud[kind] ?? []
            for id in local where !out.contains(id) { out.append(id) }
            return Array(out.prefix(caps[kind] ?? 200))
        }
        let newHist = merged("hist", lib.history)
        let newFav = merged("fav", lib.favorites)
        let newWl = merged("wl", lib.watchLater)
        // 本地独有 → 补传
        await push(kind: "hist", ids: newHist.filter { !(cloud["hist"] ?? []).contains($0) }, user: user)
        await push(kind: "fav", ids: newFav.filter { !(cloud["fav"] ?? []).contains($0) }, user: user)
        await push(kind: "wl", ids: newWl.filter { !(cloud["wl"] ?? []).contains($0) }, user: user)
        await MainActor.run {
            lib.history = newHist
            lib.favorites = newFav
            lib.watchLater = newWl
        }
    }

    static func push(kind: String, ids: [String], user: String) async {
        guard !ids.isEmpty else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        let body: [[String: Any]] = ids.map {
            ["username": user, "kind": kind, "video_id": $0, "watched_at": now]
        }
        try? await SB.insert("rest/v1/cloud_user_data", body: body,
                             prefer: "resolution=merge-duplicates,return=minimal")
    }

    static func remove(kind: String, id: String, user: String) async {
        try? await SB.delete("rest/v1/cloud_user_data", query: [
            URLQueryItem(name: "username", value: "eq." + user),
            URLQueryItem(name: "kind", value: "eq." + kind),
            URLQueryItem(name: "video_id", value: "eq." + id),
        ])
    }
}

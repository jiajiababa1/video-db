import Foundation

/// 站长管理 RPC (与网站管理面板同一套后端, 全部凭登录 token 鉴权):
/// admin_exec / admin_reset_password / admin_delete_videos / admin_announce_* /
/// admin_broadcast_dm / admin_sitepage_* / admin_config / admin_*_code / admin_recent_*
enum AdminAPI {
    private static var token: String { Session.shared.loginToken }

    struct Res: Decodable {
        var ok: Bool?
        var message: String?
        var deleted: FlexInt?
        var sent: FlexInt?
        var code: String?
    }

    private static func outcome(_ rows: [Res]) -> (Bool, String) {
        guard let r = rows.first else { return (false, "无返回") }
        return (r.ok ?? false, r.message ?? "")
    }

    // MARK: - 用户
    static func exec(action: String, target: String, detail: String) async -> (Bool, String) {
        let rows: [Res] = (try? await SB.rpc("admin_exec", [
            "p_token": token, "p_action": action, "p_target": target, "p_detail": detail,
        ])) ?? []
        return outcome(rows)
    }

    static func resetPassword(target: String, newPassword: String) async -> (Bool, String) {
        let rows: [Res] = (try? await SB.rpc("admin_reset_password", [
            "p_token": token, "p_target": target, "p_new_password": newPassword,
        ])) ?? []
        return outcome(rows)
    }

    /// 与网站同算法: 在现有到期时间 (未过期时) 之上叠加分钟数; perm 则永久
    static func setVip(user: String, level: String, minutes: Int?, permanent: Bool) async -> (Bool, String) {
        var exp: String? = nil
        if !permanent {
            struct ExpRow: Decodable { var vip_expires_at: String? }
            let cur: ([ExpRow], Int?) = (try? await SB.get("rest/v1/user_accounts", query: [
                URLQueryItem(name: "username", value: "eq." + user),
                URLQueryItem(name: "select", value: "vip_expires_at"),
                URLQueryItem(name: "limit", value: "1"),
            ])) ?? ([], nil)
            var base = Date()
            if let s = cur.0.first?.vip_expires_at, let d = ISODate.parse(s), d > Date() { base = d }
            exp = ISO8601DateFormatter().string(from: base.addingTimeInterval(Double(minutes ?? 0) * 60))
        }
        let detailObj: [String: Any] = ["level": level, "expires_at": exp ?? NSNull(), "perm": permanent]
        let detail = (try? JSONSerialization.data(withJSONObject: detailObj))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return await exec(action: "set_vip", target: user, detail: detail)
    }

    // MARK: - 视频
    static func deleteVideos(ids: [String]) async -> Int {
        let rows: [Res] = (try? await SB.rpc("admin_delete_videos", [
            "p_token": token, "p_ids": ids,
        ])) ?? []
        return rows.first?.deleted?.value ?? 0
    }

    // MARK: - 公告
    static func announcePublish(title: String, content: String) async -> (Bool, String) {
        let rows: [Res] = (try? await SB.rpc("admin_announce_publish", [
            "p_token": token, "p_title": title, "p_content": content, "p_only": false,
        ])) ?? []
        return outcome(rows)
    }

    static func announceDelete(id: Int) async -> Bool {
        let rows: [Res] = (try? await SB.rpc("admin_announce_delete", [
            "p_token": token, "p_id": id,
        ])) ?? []
        return rows.first?.ok ?? false
    }

    static func announceClear() async -> Bool {
        let rows: [Res] = (try? await SB.rpc("admin_announce_clear", [
            "p_token": token,
        ])) ?? []
        return rows.first?.ok ?? false
    }

    // MARK: - 广播私信 (留空对象 = 全体未封禁用户, 与网站同逻辑)
    static func broadcastDM(recipientsText: String, content: String) async -> Int {
        var recipients: [String] = []
        let names = recipientsText.split(whereSeparator: { ",，、 ".contains($0) }).map(String.init)
        if !names.isEmpty {
            recipients = names
        } else {
            struct URow: Decodable { var username: String? }
            let result: ([URow], Int?) = (try? await SB.get("rest/v1/user_accounts", query: [
                URLQueryItem(name: "banned", value: "eq.false"),
                URLQueryItem(name: "select", value: "username"),
                URLQueryItem(name: "limit", value: "500"),
            ])) ?? ([], nil)
            recipients = result.0.compactMap { $0.username }.filter { $0 != Session.shared.username }
        }
        guard !recipients.isEmpty else { return 0 }
        let rows: [Res] = (try? await SB.rpc("admin_broadcast_dm", [
            "p_token": token, "p_recipients": recipients, "p_content": content,
        ])) ?? []
        return rows.first?.sent?.value ?? 0
    }

    // MARK: - 站内页 / 配置
    static func sitepageSave(slug: String, title: String, content: String) async -> (Bool, String) {
        let rows: [Res] = (try? await SB.rpc("admin_sitepage_save", [
            "p_token": token, "p_slug": slug, "p_title": title, "p_content": content,
        ])) ?? []
        return outcome(rows)
    }

    static func sitepageDelete(slug: String) async -> Bool {
        let rows: [Res] = (try? await SB.rpc("admin_sitepage_delete", [
            "p_token": token, "p_slug": slug,
        ])) ?? []
        return rows.first?.ok ?? false
    }

    static func configSet(key: String, value: String) async -> Bool {
        let rows: [Res] = (try? await SB.rpc("admin_config", [
            "p_token": token, "p_key": key, "p_value": value,
        ])) ?? []
        return rows.first?.ok ?? false
    }

    // MARK: - 兑换码
    struct CodeRow: Decodable, Identifiable {
        var code: String?
        var level: String?
        var uses: FlexInt?
        var used_count: FlexInt?
        var permanent: Bool?
        var created_at: String?
        var id: String { code ?? UUID().uuidString }
    }

    static func listCodes() async -> [CodeRow] {
        (try? await SB.rpc("admin_list_codes", ["p_token": token])) ?? []
    }

    static func generateCode(level: String, uses: Int, minutes: Int, permanent: Bool) async -> String? {
        let rows: [Res] = (try? await SB.rpc("admin_generate_code", [
            "p_token": token, "p_level": level, "p_uses": uses,
            "p_duration_minutes": minutes, "p_permanent": permanent,
        ])) ?? []
        return rows.first?.code
    }

    // MARK: - 总览类
    struct RecentMsg: Decodable, Identifiable {
        var from_user: String?
        var to_user: String?
        var content: String?
        var created_at: String?
        var id: String { (from_user ?? "") + (to_user ?? "") + (created_at ?? "") + (content ?? "") }
        enum CodingKeys: String, CodingKey { case from_user, to_user, content, created_at }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            from_user = try? c.decode(String.self, forKey: .from_user)
            to_user = try? c.decode(String.self, forKey: .to_user)
            content = try? c.decode(String.self, forKey: .content)
            created_at = try? c.decode(String.self, forKey: .created_at)
        }
    }

    static func recentMessages(limit: Int = 100) async -> [RecentMsg] {
        (try? await SB.rpc("admin_recent_messages", ["p_token": token, "p_limit": limit])) ?? []
    }

    struct BanRow: Decodable, Identifiable {
        var username: String?
        var reason: String?
        var banned_by: String?
        var created_at: String?
        var id: String { (username ?? "") + (created_at ?? "") }
    }

    static func recentBans() async -> [BanRow] {
        (try? await SB.rpc("admin_recent_bans", ["p_token": token])) ?? []
    }

    // MARK: - 灵活读取 (管理列表字段不一, 用字典兜底)
    static func restRows(_ path: String, query: [URLQueryItem]) async -> [[String: Any]] {
        var comp = URLComponents(url: SB.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        comp?.queryItems = query
        guard let url = comp?.url else { return [] }
        var req = URLRequest(url: url)
        for (k, v) in await SB.headers() { req.setValue(v, forHTTPHeaderField: k) }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr
    }

    static func restCount(_ path: String, query: [URLQueryItem]) async -> Int? {
        struct E: Decodable {}
        let (_, total): ([E], Int?) = (try? await SB.get(path, query: query)) ?? ([], nil)
        return total
    }
}

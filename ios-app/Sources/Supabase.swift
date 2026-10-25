import Foundation

/// Supabase REST 客户端 (与网站同一后端、同一 anon key; 数据由 RLS 保护)
enum SB {
    static let base = URL(string: "https://fejspvbckgkbmfyoxiub.supabase.co")!
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZlanNwdmJja2drYm1meW94aXViIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA0ODczNzcsImV4cCI6MjA5NjA2MzM3N30.L1jV0XWpE69nQVgZWmAxjOGTALpfmD7xflcO2Yb5Z14"

    static func headers(extra: [String: String] = [:]) -> [String: String] {
        var h = [
            "apikey": anonKey,
            "Authorization": "Bearer " + anonKey,
            "Content-Type": "application/json",
            "x-login-token": Session.shared.loginToken,
        ]
        for (k, v) in extra { h[k] = v }
        return h
    }

    /// GET 查询, 返回解码结果与总条数 (Prefer: count=exact 时从 Content-Range 解析)
    static func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> (T, Int?) {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = query
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        for (k, v) in headers(extra: ["Prefer": "count=exact"]) { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        var total: Int? = nil
        if let http = resp as? HTTPURLResponse,
           let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let tail = cr.split(separator: "/").last {
            total = Int(tail)
        }
        let decoded = try JSONDecoder().decode(T.self, from: data)
        return (decoded, total)
    }

    /// PATCH 更新行 (query 里给匹配条件, 如 video_id=eq.xxx)
    static func patch(_ path: String, query: [URLQueryItem], body: [String: Any]) async throws {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = query
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "PATCH"
        for (k, v) in headers(extra: ["Prefer": "return=minimal"]) { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
    }

    /// POST 插入 / RPC 调用
    static func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        for (k, v) in headers(extra: ["Prefer": "return=representation"]) { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        if T.self == EmptyResp.self { return EmptyResp() as! T }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func rpc<T: Decodable>(_ name: String, params: [String: Any]) async throws -> T {
        try await post("rest/v1/rpc/" + name, body: params)
    }

    /// 原始 URL 字符串 GET (查询串由调用方按 PostgREST 语法手工拼装, 与网站一致)
    static func getRaw<T: Decodable>(_ urlString: String) async throws -> (T, Int?) {
        var req = URLRequest(url: URL(string: urlString)!)
        req.httpMethod = "GET"
        for (k, v) in headers(extra: ["Prefer": "count=exact"]) { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        var total: Int? = nil
        if let http = resp as? HTTPURLResponse,
           let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let tail = cr.split(separator: "/").last {
            total = Int(tail)
        }
        let decoded = try JSONDecoder().decode(T.self, from: data)
        return (decoded, total)
    }

    /// POST 直接写表 (upsert 时 headers 追加 Prefer)
    static func insert(_ path: String, body: Any, prefer: String? = nil) async throws {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        var extra: [String: String] = ["Prefer": "return=minimal"]
        if let prefer = prefer { extra["Prefer"] = prefer }
        for (k, v) in headers(extra: extra) { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
    }

    static func delete(_ path: String, query: [URLQueryItem]) async throws {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = query
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "DELETE"
        for (k, v) in headers() { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        if !(200..<300).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Supabase", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(msg.prefix(200))"])
        }
    }
}

struct EmptyResp: Decodable {}

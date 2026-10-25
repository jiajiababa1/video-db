import Foundation

/// 播放地址解析 (与网站 resolveVideoSource 同顺序: 存量直链 → hsex 现抓 → twjn → FxTwitter)
enum Resolver {

    static func resolve(_ v: VideoItem) async -> URL? {
        // hsex: 存量新鲜直链优先, 否则现抓详情页
        if v.isHx {
            if v.storedHxFresh, let u = v.storedURL { return u }
            if let u = await resolveHsex(v) {
                writeback(v, u)
                return u
            }
            return nil
        }
        // 存量直链 (mp4 / twimg / m3u8)
        if let u = v.storedURL { return u }
        // 热更新 JS 解析模块 (命中前缀时优先于内置解析)
        if let u = Bridge.shared.resolveWithModules(v) {
            writeback(v, u)
            return u
        }
        // twjn 解析
        if let mid = v.monsnode_video_id, !mid.isEmpty, let u = await resolveTwjn(mid) {
            writeback(v, u)
            return u
        }
        // FxTwitter 兜底
        if let tid = tweetId(v), let u = await resolveFx(tid) {
            writeback(v, u)
            return u
        }
        return nil
    }

    // MARK: - hsex
    static func resolveHsex(_ v: VideoItem) async -> URL? {
        guard let page = v.video_url, let url = URL(string: page) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let html = String(data: data, encoding: .utf8) else { return nil }
        return extract(pattern: #"https://cdn\.hdcdn\.store/[^"'\s]+/index\.m3u8"#, in: html)
            .flatMap { URL(string: $0) }
    }

    // MARK: - twjn (原生直连, 无 CORS 限制)
    static func resolveTwjn(_ mid: String) async -> URL? {
        let rand = String(UUID().uuidString.prefix(8))
        let urlStr = "https://monsnode.com/twjn.php?v=" + mid + "&_r=" + rand
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let html = String(data: data, encoding: .utf8), html.count >= 5 else { return nil }
        // 判死: 短正文 + 失效关键词
        if html.count <= 1500 {
            let dead = ["not found", "not_found", "invalid", "expired", "已被删除", "不存在", "fail"]
            let low = html.lowercased()
            if dead.contains(where: { low.contains($0) }) { return nil }
        }
        // 1) var u = atob('...')
        if let b64 = extract(pattern: #"var\s+u\s*=\s*atob\(\s*'([^']+)'\s*\)"#, in: html)
            ?? extract(pattern: #"var\s+u\s*=\s*atob\(\s*"([^"]+)"\s*\)"#, in: html),
           let s = decodeB64(b64), s.contains("video.twimg.com") {
            return URL(string: s)
        }
        // 2) 全文 atob 扫描
        for b64 in extractAll(pattern: #"atob\(\s*'([^']{20,})'\s*\)"#, in: html) {
            if let s = decodeB64(b64), s.contains("video.twimg.com") { return URL(string: s) }
        }
        // 3) 裸链
        if let s = extract(pattern: #"https?://[^\s"'\\\)<>]*video\.twimg\.com[^\s"'\\\)<>]*"#, in: html) {
            return URL(string: s.replacingOccurrences(of: "&amp;", with: "&"))
        }
        return nil
    }

    // MARK: - FxTwitter
    static func tweetId(_ v: VideoItem) -> String? {
        // video_id / monsnode_video_id 中的长数字串即推文 id
        for cand in [v.monsnode_video_id ?? "", v.video_id] {
            let digits = cand.filter { $0.isNumber }
            if digits.count >= 15 { return digits }
        }
        return nil
    }

    static func resolveFx(_ tid: String) async -> URL? {
        for host in ["api.fxtwitter.com", "api.vxtwitter.com"] {
            guard let url = URL(string: "https://" + host + "/status/" + tid) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 12
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tweet = obj["tweet"] as? [String: Any],
                  let media = tweet["media"] as? [String: Any],
                  let videos = media["videos"] as? [[String: Any]] else { continue }
            let best = videos.max { (a, b) in
                ((a["bitrate"] as? Int) ?? 0) < ((b["bitrate"] as? Int) ?? 0)
            }
            if let u = best?["url"] as? String, let url = URL(string: u) { return url }
        }
        return nil
    }

    // MARK: - 回写
    static func writeback(_ v: VideoItem, _ url: URL) {
        Task {
            let _: [EmptyResp] = (try? await SB.rpc("submit_mp4",
                params: ["p_video_id": v.video_id, "p_mp4_url": url.absoluteString])) ?? []
        }
    }

    /// 播放失败自动标记待重爬 (与网站 renderVideoError 一致)
    static func markRescrape(_ v: VideoItem) {
        Task {
            try? await SB.patch("rest/v1/videos",
                query: [URLQueryItem(name: "video_id", value: "eq." + v.video_id)],
                body: ["needs_rescrape": true,
                       "updated_at": ISO8601DateFormatter().string(from: Date())])
        }
    }

    // MARK: - 工具
    static func extract(pattern: String, in text: String) -> String? {
        extractAll(pattern: pattern, in: text).first
    }

    static func extractAll(pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            m.numberOfRanges > 1 ? ns.substring(with: m.range(at: 1)) : ns.substring(with: m.range)
        }
    }

    static func decodeB64(_ s: String) -> String? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        guard let d = Data(base64Encoded: t) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

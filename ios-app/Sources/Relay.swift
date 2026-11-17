import Foundation

/// Cloudflare 中转 (v5.4): Twitter CDN 在国内直连基本不可达, 封面和视频先经
/// vdb-relay Worker 转发 (只放行 video.twimg.com / pbs.twimg.com 两个域名),
/// 目标是关掉梯子也能刷封面、播视频。路径风格: /<host>/<原路径>?<原参数>。
/// 只在真正加载/播放/下载的那一刻改写; 数据库回存、playable 判定仍用原始地址。
enum Relay {
    static let base = "https://vdb-relay.2127168031.workers.dev"
    private static let hosts: Set<String> = ["video.twimg.com", "pbs.twimg.com"]

    /// twimg 域名改写成中转地址, 其余域名 (含 hsex 的 m3u8) 原样返回
    static func rewrite(_ url: URL) -> URL {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = comps.host?.lowercased(), hosts.contains(host) else { return url }
        var s = base + "/" + host + comps.percentEncodedPath
        if let q = comps.percentEncodedQuery, !q.isEmpty { s += "?" + q }
        return URL(string: s) ?? url
    }

    /// String 版: 解析不了或非 twimg 域名时原样返回
    static func rewrite(_ s: String) -> String {
        guard let u = URL(string: s) else { return s }
        return rewrite(u).absoluteString
    }
}

import Foundation

/// videos 表行 (字段与网站列表查询 SS_COLS 对齐)
struct VideoItem: Codable, Identifiable, Hashable {
    var video_id: String
    var title: String?
    var author: String?
    var thumbnail_url: String?
    var duration: String?          // 约定: has_mp4 时这里存的是可播放直链, 否则是时长文本
    var source_section: String?
    var views: String?
    var has_mp4: Bool?
    var needs_rescrape: Bool?
    var video_url: String?
    var vote_up: Int?
    var vote_down: Int?
    var created_at: String?
    var monsnode_video_id: String?
    var source_page: String?
    var playable: Bool?
    var vip_early: Bool?

    var id: String { video_id }

    var displayTitle: String { (title?.isEmpty == false) ? title! : "无标题" }
    var displayAuthor: String { author ?? "" }

    var isHx: Bool { video_id.hasPrefix("hx_") }

    /// duration 里存的直链 (http 开头且像媒体地址时)
    var storedURL: URL? {
        guard let d = duration, d.hasPrefix("http") else { return nil }
        if d.contains(".mp4") || d.contains("video.twimg.com") || d.contains(".m3u8") {
            return URL(string: d)
        }
        return nil
    }

    /// 卡片上显示的时长文本 (duration 是直链时不显示)
    var durationText: String? {
        guard let d = duration, !d.hasPrefix("http"), !d.isEmpty else { return nil }
        return d
    }

    /// 存量 hsex 链接是否还新鲜 (签名过期时间戳 > 当前 + 2 分钟)
    var storedHxFresh: Bool {
        guard isHx, let d = duration else { return false }
        guard let r = d.range(of: "cdn.hdcdn.store/") else { return false }
        let rest = d[r.upperBound...]
        guard let seg = rest.split(separator: "/").first, let exp = Double(seg) else { return false }
        return exp * 1000 - Date().timeIntervalSince1970 * 1000 > 120_000
    }

    var viewsText: String? {
        guard let v = views, !v.isEmpty else { return nil }
        return v.hasSuffix("次观看") || v.contains("播放") ? v : "▶ " + v
    }
}

/// 列表查询参数
struct VideoQuery {
    var section: AppSection? = nil
    var playableOnly: Bool = true       // 与网站默认「✅ 可播」一致
    var search: String? = nil           // 标题关键词
    var author: String? = nil
    var sortHot: Bool = false
    var limit: Int = 30
    var offset: Int = 0
}

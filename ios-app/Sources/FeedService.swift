import Foundation

/// 视频列表查询 (与网站 ssBaseFilters / fetchVids 同口径)
enum FeedService {
    static let pageSize = 24
    static let cols = "select=video_id,title,author,thumbnail_url,duration,source_page,source_section,views,created_at,vote_up,vote_down,has_mp4,needs_rescrape,playable,video_url,monsnode_video_id,vip_early"

    static let allSections: [AppSection] = [
        AppSection(id: "", name: "全部视频", subtitle: "全站视频流", isSource: false),
        AppSection(id: "home", name: "首页推荐", subtitle: "精选推荐", isSource: false),
        AppSection(id: "latest", name: "最新上传", subtitle: "刚入库的新片", isSource: false),
        AppSection(id: "trending", name: "热门趋势", subtitle: "按观看量", isSource: false),
        AppSection(id: "ranking", name: "综合排行", subtitle: "按观看量", isSource: false),
        AppSection(id: "24h", name: "24 小时", subtitle: "一天内热度", isSource: false),
        AppSection(id: "3d", name: "3 天", subtitle: "三天内热度", isSource: false),
        AppSection(id: "7d", name: "7 天", subtitle: "一周内热度", isSource: false),
        AppSection(id: "hsex", name: "Hsex 视频", subtitle: "中文专栏", isSource: false),
    ]

    /// PostgREST 参数转义 (与网站 pgSan 一致: 替换 ()\, 为空格)
    static func pgSan(_ s: String) -> String {
        s.replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "\\", with: " ")
    }

    private static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    /// 拼过滤串 (不含 select/order/limit), 与网站 ssBaseFilters 等价
    static func filterString(section: AppSection?, playableOnly: Bool, author: String?,
                             search: String?, personalIds: [String]?) -> String {
        var p = ""
        var inMode = false
        if let ids = personalIds {
            if ids.isEmpty { return "" }  // 空列表 = 不发请求
            let list = ids.map { "%22" + enc($0) + "%22" }.joined(separator: ",")
            p += "&video_id=in.(" + list + ")"
            inMode = true
        } else if let sec = section, !sec.id.isEmpty {
            p += "&source_section=ilike.*" + enc(pgSan(sec.id)) + "*"
        }
        if let a = author, !a.isEmpty {
            p += "&author=ilike.*" + enc(pgSan(a.trimmingCharacters(in: .whitespaces))) + "*"
        }
        if !inMode {
            p += "&or=(source_section.is.null,source_section.not.ilike.*av4*)"
            p += "&or=(source_section.is.null,source_section.not.in.(twidouga,twivideo,iwara))"
        }
        if playableOnly {
            p += "&or=(has_mp4.is.true,duration.ilike.*video.twimg.com*)"
        }
        if let q = search, !q.trimmingCharacters(in: .whitespaces).isEmpty {
            let qq = enc(pgSan(q.trimmingCharacters(in: .whitespaces)))
            p += "&or=(title.ilike.*" + qq + "*,author.ilike.*" + qq + "*)"
        }
        p += "&removed=not.is.true"
        return p
    }

    static func fetchPage(section: AppSection? = nil, playableOnly: Bool = true,
                          author: String? = nil, search: String? = nil,
                          personalIds: [String]? = nil, page: Int = 1,
                          hotSort: Bool = false) async throws -> (items: [VideoItem], total: Int?) {
        let filters = filterString(section: section, playableOnly: playableOnly,
                                   author: author, search: search, personalIds: personalIds)
        if personalIds != nil && filters.isEmpty { return ([], 0) }
        let hot = hotSort || section?.id == "ranking" || section?.id == "trending"
        let order = hot ? "views.desc.nullslast" : "created_at.desc,video_id.desc"
        let offset = (page - 1) * pageSize
        let url = SB.base.absoluteString + "/rest/v1/videos?" + cols + filters
            + "&order=" + order + "&limit=" + String(pageSize) + "&offset=" + String(offset)
        let (rows, total): ([VideoItem], Int?) = try await SB.getRaw(url)
        return (rows, total)
    }

    /// 栏目计数 (单独的 count 查询, 与网站计数口径一致)
    static func count(section: AppSection) async -> Int? {
        let filters = filterString(section: section, playableOnly: true, author: nil, search: nil, personalIds: nil)
        let url = SB.base.absoluteString + "/rest/v1/videos?select=video_id" + filters + "&limit=1"
        let (_, total): ([VideoItem], Int?) = (try? await SB.getRaw(url)) ?? ([], nil)
        return total
    }

    /// 按 id 批量取行 (个人栏目/收藏刷新用)
    static func fetchByIds(_ ids: [String]) async -> [VideoItem] {
        guard !ids.isEmpty else { return [] }
        let list = ids.map { "%22" + enc($0) + "%22" }.joined(separator: ",")
        let url = SB.base.absoluteString + "/rest/v1/videos?" + cols
            + "&video_id=in.(" + list + ")&limit=" + String(ids.count)
        let (rows, _): ([VideoItem], Int?) = (try? await SB.getRaw(url)) ?? ([], nil)
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.video_id, $0) })
        return ids.compactMap { byId[$0] }
    }

    /// 全站总数 (数据主页用)
    static func totalCount() async -> Int? {
        let url = SB.base.absoluteString + "/rest/v1/videos?select=video_id&removed=not.is.true&limit=1"
        let (_, total): ([VideoItem], Int?) = (try? await SB.getRaw(url)) ?? ([], nil)
        return total
    }
}

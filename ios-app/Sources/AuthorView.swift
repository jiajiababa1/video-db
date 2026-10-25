import SwiftUI

/// 作者主页: 头像/统计/关注屏蔽 + TA 的作品 + TA 的全部视频。
/// 入口: 视频卡片作者名、播放页作者行、关注列表、搜索作者结果。
struct AuthorView: View {
    let name: String
    @EnvironmentObject var library: Library
    @EnvironmentObject var session: Session
    @State private var videoTotal: Int? = nil
    @State private var viewsTotal: Int? = nil
    @State private var works: [WorkItem] = []
    @State private var playURL: IdentifiedString? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            if !works.isEmpty {
                worksStrip
            }
            FeedView(author: name, showAuthorBar: false)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("@" + name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $playURL) { w in
            SimpleVideoPlayer(urlString: w.value)
        }
        .task { await loadMeta() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.goldGradient)
                Text(String(name.prefix(1)))
                    .font(.system(size: 24, weight: .bold)).foregroundColor(.black)
            }
            .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text("@" + name)
                    .font(.system(size: 17, weight: .bold)).lineLimit(1)
                Text(statsText)
                    .font(.caption).foregroundColor(Theme.sub)
            }
            Spacer()
            VStack(spacing: 6) {
                Button(library.isFollowing(name) ? "已关注" : "+ 关注") {
                    library.toggleFollow(name)
                }
                .font(.system(size: 13, weight: .bold))
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(library.isFollowing(name) ? Theme.surface2 : Theme.gold)
                .foregroundColor(library.isFollowing(name) ? Theme.text : .black)
                .cornerRadius(99)
                Button(library.isBlocked(name) ? "已屏蔽" : "屏蔽作者") {
                    library.toggleBlock(name)
                }
                .font(.system(size: 11.5))
                .foregroundColor(Theme.sub)
            }
        }
        .padding(14)
        .background(Theme.surface)
    }

    private var statsText: String {
        var parts: [String] = []
        if let t = videoTotal { parts.append("视频 \(t) 个") }
        if let v = viewsTotal, v > 0 { parts.append("总播放 \(formatCount(v))") }
        if !works.isEmpty { parts.append("作品 \(works.count) 个") }
        return parts.isEmpty ? "作者主页" : parts.joined(separator: " · ")
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 10000 { return String(format: "%.1f万", Double(n) / 10000) }
        return String(n)
    }

    private var worksStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TA 的作品")
                .font(.system(size: 14, weight: .bold))
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(works) { w in
                        VStack(alignment: .leading, spacing: 4) {
                            ZStack {
                                CachedImage(urlString: w.cover_url)
                                    .frame(width: 150)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                    .clipped()
                                Image(systemName: "play.circle.fill")
                                    .foregroundColor(.white.opacity(0.9))
                            }
                            .cornerRadius(10)
                            Text(w.title ?? "无标题")
                                .font(.caption).lineLimit(1).frame(width: 150, alignment: .leading)
                        }
                        .onTapGesture {
                            if let f = w.file_url { playURL = IdentifiedString(value: f) }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 10)
        .background(Theme.surface.opacity(0.55))
    }

    private func loadMeta() async {
        // 视频总数: 走 FeedService 同口径取 total
        if let r = try? await FeedService.fetchPage(author: name, page: 1) {
            videoTotal = r.total
        }
        // 总播放: 聚合该作者视频的 views (最多取 500 条求和)
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let url = SB.base.absoluteString + "/rest/v1/videos?select=views&author=eq." + enc
            + "&removed=not.is.true&limit=500"
        struct VRow: Decodable { var views: FlexInt? }
        let (rows, _): ([VRow], Int?) = (try? await SB.getRaw(url)) ?? ([], nil)
        if !rows.isEmpty {
            viewsTotal = rows.reduce(0) { $0 + ($1.views?.value ?? 0) }
        }
        // TA 的作品
        let all = await SocialAPI.works()
        works = all.filter { $0.author == name }
    }
}

import SwiftUI
import UIKit

// 由 Features21.swift 拆分 (v5.2: 每个功能一个文件, 方便定位问题)

enum LikesAPI {
    struct Status: Decodable { var liked: Bool?; var total: Int? }
    struct Toggle: Decodable { var ok: Bool?; var liked: Bool?; var total: Int? }
    struct Mine: Decodable { var video_id: String? }

    static func status(_ videoId: String) async -> (liked: Bool, total: Int) {
        let rows: [Status]? = try? await SB.rpc("like_status", params: [
            "p_token": Session.shared.loginToken, "p_video_id": videoId])
        if let r = rows?.first { return (r.liked ?? false, r.total ?? 0) }
        return (false, 0)
    }

    static func toggle(_ videoId: String) async -> (liked: Bool, total: Int)? {
        let rows: [Toggle]? = try? await SB.rpc("toggle_like", params: [
            "p_token": Session.shared.loginToken, "p_video_id": videoId])
        guard let r = rows?.first, r.ok == true else { return nil }
        return (r.liked ?? false, r.total ?? 0)
    }

    static func myLikedIds(limit: Int = 100) async -> [String] {
        let rows: [Mine]? = try? await SB.rpc("my_likes", params: [
            "p_token": Session.shared.loginToken, "p_limit": limit])
        return (rows ?? []).compactMap { $0.video_id }
    }
}

// MARK: - 服务端观看进度同步 (网站 ↔ App 续播)

struct LikedVideosView: View {
    @EnvironmentObject var session: Session
    @State private var items: [VideoItem] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if !session.isLoggedIn {
                hint("登录后这里会同步你点赞过的视频")
            } else if loaded && items.isEmpty {
                hint("还没点赞过视频\n在刷视频里双击或点爱心就是点赞")
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(items) { v in
                            VideoRowLink(v: v)
                                .padding(.horizontal, 16)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("我赞过的")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !loaded {
                loaded = true
                await load()
            }
        }
    }

    private func hint(_ t: String) -> some View {
        Text(t)
            .multilineTextAlignment(.center)
            .font(.footnote).foregroundColor(Theme.sub)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        let ids = await LikesAPI.myLikedIds()
        guard !ids.isEmpty else { return }
        let url = SB.base.absoluteString + "/rest/v1/videos?" + FeedService.cols
            + "&removed=not.is.true&video_id=" + pgInList(ids) + "&limit=100"
        let (rows, _): ([VideoItem], Int?) = (try? await SB.getRaw(url)) ?? ([], nil)
        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        items = rows.sorted { (order[$0.video_id] ?? 999) < (order[$1.video_id] ?? 999) }
    }
}

// MARK: - 作者排行榜 (服务端缓存榜, 每小时刷新)

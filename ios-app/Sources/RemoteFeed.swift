import SwiftUI
import UIKit

// 由 Features21.swift 拆分 (v5.2: 每个功能一个文件, 方便定位问题)

struct VideoRowLink: View {
    let v: VideoItem
    @State private var showShare = false

    var body: some View {
        NavigationLink {
            PlayerView(video: v)
        } label: {
            HStack(spacing: 10) {
                CachedImage(urlString: v.thumbnail_url ?? "")
                    .frame(width: 104, height: 62)
                    .clipped()
                    .cornerRadius(8)
                VStack(alignment: .leading, spacing: 4) {
                    Text(v.displayTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(2)
                        .foregroundColor(Theme.text)
                    if !v.displayAuthor.isEmpty {
                        Text("@" + v.displayAuthor)
                            .font(.caption).foregroundColor(Theme.sub)
                    }
                    if let t = v.viewsText {
                        Text(t + " 观看")
                            .font(.caption2).foregroundColor(Theme.sub)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                showShare = true
            } label: {
                Label("分享给朋友", systemImage: "paperplane")
            }
        }
        .sheet(isPresented: $showShare) {
            ShareToFriendView(video: v)
        }
    }
}

/// 通用视频列表页 (关注更新 / 今日新增 共用骨架, 上拉分页由 onAppear 触发)
struct RemoteFeedView: View {
    let navTitle: String
    let emptyText: String
    /// (page) -> 追加在 cols 之后的过滤串 (以 & 开头); nil 表示没有更多过滤条件
    let filterForPage: (Int) -> String

    @State private var items: [VideoItem] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded && items.isEmpty {
                Text(emptyText)
                    .font(.footnote).foregroundColor(Theme.sub)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(items) { v in
                            VideoRowLink(v: v)
                                .padding(.horizontal, 16)
                        }
                        if hasMore {
                            ProgressView()
                                .tint(Theme.gold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .onAppear { Task { await loadMore() } }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !loaded {
                loaded = true
                await loadMore()
            }
        }
    }

    private func loadMore() async {
        let p = page
        let url = SB.base.absoluteString + "/rest/v1/videos?" + FeedService.cols
            + filterForPage(p)
            + "&order=created_at.desc,video_id.desc&limit=24&offset=" + String((p - 1) * 24)
        let (rows, _): ([VideoItem], Int?) = (try? await SB.getRaw(url)) ?? ([], nil)
        items.append(contentsOf: rows)
        hasMore = rows.count >= 24
        page = p + 1
    }
}

struct TodayFeedView: View {
    var body: some View {
        RemoteFeedView(navTitle: "今日新增", emptyText: "今天还没有新入库的视频") { _ in
            "&removed=not.is.true&created_at=gte." + Self.todayStartISO + playableOrFilter
        }
    }

    private static var todayStartISO: String {
        let start = Calendar.current.startOfDay(for: Date())
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: start)
    }
}

// MARK: - 我赞过的

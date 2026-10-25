import SwiftUI

/// 视频卡片 (新版设计: 大圆角 + 时长/观看量徽标)
struct VideoCard: View {
    let video: VideoItem
    var progress: Double? = nil
    @EnvironmentObject var library: Library

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                CachedImage(urlString: video.thumbnail_url)
                    .aspectRatio(16 / 9, contentMode: .fit)
                HStack {
                    if let vt = video.viewsText {
                        Text(vt).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.black.opacity(0.55)).cornerRadius(5)
                    }
                    Spacer()
                    if let dt = video.durationText {
                        Text(dt).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.black.opacity(0.72)).cornerRadius(5)
                    }
                }
                .padding(6)
            }
            if let p = progress, p > 0.01, p < 0.99 {
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                    .tint(Theme.gold)
                    .background(Theme.line)
                    .scaleEffect(x: 1, y: 0.7, anchor: .center)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(video.displayTitle)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .frame(minHeight: 32, alignment: .topLeading)
                HStack(spacing: 5) {
                    if !video.displayAuthor.isEmpty {
                        Text("@" + video.displayAuthor)
                            .lineLimit(1)
                    }
                    if let vt = video.viewsText {
                        Text("· " + vt.replacingOccurrences(of: "▶ ", with: ""))
                            .lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundColor(Theme.sub)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
        }
        .background(Theme.surface)
        .cornerRadius(Theme.cardRadius)
        .contextMenu {
            Button {
                library.toggleFav(video)
            } label: {
                Label(library.isFav(video.video_id) ? "取消收藏" : "收藏",
                      systemImage: library.isFav(video.video_id) ? "bookmark.fill" : "bookmark")
            }
            Button {
                library.toggleWatchLater(video)
            } label: {
                Label(library.isWatchLater(video.video_id) ? "移出稍后看" : "稍后看",
                      systemImage: "clock")
            }
            if !video.displayAuthor.isEmpty {
                Button {
                    library.toggleFollow(video.displayAuthor)
                } label: {
                    Label(library.isFollowing(video.displayAuthor) ? "取消关注作者" : "关注作者",
                          systemImage: "person.badge.plus")
                }
                Button(role: .destructive) {
                    library.toggleBlock(video.displayAuthor)
                } label: {
                    Label(library.isBlocked(video.displayAuthor) ? "取消屏蔽作者" : "屏蔽作者",
                          systemImage: "eye.slash")
                }
            }
            Button {
                Task {
                    // 与网站一致: 先现场解析一次, 成功直接回写, 失败才进重爬队列
                    if await Resolver.resolve(video) == nil {
                        Resolver.markRescrape(video)
                    }
                }
            } label: {
                Label("标记重爬", systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }
}

/// 双列网格 (带分页触发)
struct VideoGrid: View {
    let items: [VideoItem]
    var progressOf: ((VideoItem) -> Double?)? = nil
    var onReachEnd: (() -> Void)? = nil

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(items) { v in
                NavigationLink {
                    PlayerView(video: v)
                } label: {
                    VideoCard(video: v, progress: progressOf?(v))
                }
                .buttonStyle(.plain)
                .onAppear {
                    if v.id == items.last?.id { onReachEnd?() }
                }
            }
        }
    }
}

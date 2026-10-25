import SwiftUI

/// 视频卡片 (新版设计: 大圆角 + 时长/观看量徽标)
struct VideoCard: View {
    let video: VideoItem
    var progress: Double? = nil
    @EnvironmentObject var library: Library

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: URL(string: video.thumbnail_url ?? "")) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: Rectangle().fill(Theme.surface2)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipped()
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
            VStack(alignment: .leading, spacing: 3) {
                Text(video.displayTitle)
                    .font(.system(size: 13.5))
                    .lineLimit(2)
                    .frame(minHeight: 34, alignment: .topLeading)
                if !video.displayAuthor.isEmpty {
                    Text("@" + video.displayAuthor)
                        .font(.caption)
                        .foregroundColor(Theme.sub)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
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
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
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

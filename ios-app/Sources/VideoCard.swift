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
            if !library.favFolders.isEmpty {
                Menu {
                    ForEach(Array(library.favFolders.keys.sorted()), id: \.self) { f in
                        Button {
                            library.toggleInFolder(f, video)
                        } label: {
                            Label((library.favFolders[f]?.contains(video.video_id) ?? false) ? "移出「\(f)」" : "加入「\(f)」",
                                  systemImage: "folder")
                        }
                    }
                } label: {
                    Label("收藏到分组", systemImage: "folder.badge.plus")
                }
            }
            Button {
                library.toggleHidden(video)
            } label: {
                Label(library.isHidden(video.video_id) ? "取消隐藏" : "隐藏此视频",
                      systemImage: "eye.slash")
            }
            Button {
                Task {
                    if let u = await Resolver.resolve(video),
                       u.pathExtension.lowercased() != "m3u8" {
                        Downloader.shared.enqueue(video, url: u)
                    }
                }
            } label: {
                Label(Downloader.shared.isDownloaded(video.video_id) ? "已下载" : "下载到本地",
                      systemImage: "arrow.down.circle")
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

/// 骨架屏: 首屏加载时的占位卡片 (带呼吸感, 比空白转圈感知快)
struct SkeletonGrid: View {
    @State private var pulse = false

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(0..<6, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 7) {
                    RoundedRectangle(cornerRadius: 10).fill(Theme.surface2)
                        .aspectRatio(16 / 9, contentMode: .fit)
                    RoundedRectangle(cornerRadius: 4).fill(Theme.surface2)
                        .frame(height: 11)
                    RoundedRectangle(cornerRadius: 4).fill(Theme.surface2)
                        .frame(width: 80, height: 9)
                }
                .padding(6)
                .background(Theme.surface)
                .cornerRadius(Theme.cardRadius)
            }
        }
        .opacity(pulse ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
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
                    // 预热后面几张封面, 快滑不闪白
                    if let idx = items.firstIndex(where: { $0.id == v.id }) {
                        let next = items.dropFirst(idx + 1).prefix(6).compactMap { $0.thumbnail_url }
                        if !next.isEmpty {
                            Task { await ImageStore.shared.prefetch(Array(next)) }
                        }
                    }
                }
            }
        }
    }
}

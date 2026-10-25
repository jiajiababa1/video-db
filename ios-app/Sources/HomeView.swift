import SwiftUI

/// 首页: 精选大图 + 继续观看 + 栏目货架 + 推荐网格
struct HomeView: View {
    @EnvironmentObject var library: Library
    @State private var latest: [VideoItem] = []
    @State private var hx: [VideoItem] = []
    @State private var recs: [VideoItem] = []
    @State private var loading = true

    private var continueWatching: [VideoItem] {
        library.history.prefix(10).compactMap { library.snapshots[$0] }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let hero = latest.first {
                    heroView(hero)
                }
                if !continueWatching.isEmpty {
                    shelfHeader("继续观看")
                    shelf(continueWatching, showProgress: true)
                }
                shelfHeader("最新上线", section: FeedService.allSections[2])
                shelf(latest)
                shelfHeader("Hsex 专栏", section: FeedService.allSections[8])
                shelf(hx)
                shelfHeader("为你推荐")
                VideoGrid(items: recs)
                    .padding(.horizontal, 16)
            }
            .padding(.bottom, 16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("2048 影院")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    SearchView()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .overlay { if loading { ProgressView().tint(Theme.gold) } }
    }

    private func heroView(_ v: VideoItem) -> some View {
        NavigationLink {
            PlayerView(video: v)
        } label: {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: URL(string: v.thumbnail_url ?? "")) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: Rectangle().fill(Theme.surface2)
                    }
                }
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.88)],
                               startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 8) {
                    Text("今日精选")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Theme.goldGradient).foregroundColor(.black)
                        .cornerRadius(99)
                    Text(v.displayTitle)
                        .font(.system(size: 18, weight: .bold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 10) {
                        Text("▶ 播放")
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(Color.white).foregroundColor(.black)
                            .cornerRadius(99)
                        Text("@" + v.displayAuthor)
                            .font(.caption).foregroundColor(.white.opacity(0.85))
                    }
                }
                .padding(14)
            }
            .cornerRadius(22)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .buttonStyle(.plain)
    }

    private func shelfHeader(_ title: String, section: AppSection? = nil) -> some View {
        HStack {
            Text(title).font(.system(size: 17, weight: .bold))
            Spacer()
            if let sec = section {
                NavigationLink {
                    FeedView(section: sec)
                } label: {
                    Text("更多 ›").font(.caption).foregroundColor(Theme.gold)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private func shelf(_ items: [VideoItem], showProgress: Bool = false) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(items) { v in
                    NavigationLink {
                        PlayerView(video: v)
                    } label: {
                        VideoCard(video: v, progress: showProgress ? library.progress[v.video_id] : nil)
                            .frame(width: 218)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func load() async {
        loading = true
        async let a = FeedService.fetchPage(section: FeedService.allSections[2], page: 1)
        async let b = FeedService.fetchPage(section: FeedService.allSections[8], page: 1)
        async let c = FeedService.fetchPage(section: FeedService.allSections[1], page: 1)
        latest = (try? await a.items) ?? []
        hx = (try? await b.items) ?? []
        recs = (try? await c.items) ?? []
        loading = false
    }
}

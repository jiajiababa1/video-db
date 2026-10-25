import SwiftUI

/// 片库: 收藏 / 关注作者 / 稍后看 / 历史 / 我的上传
struct LibraryView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var session: Session
    @State private var tab = 0
    @State private var refreshed: [String: VideoItem] = [:]

    private let tabs = ["收藏", "关注作者", "稍后看", "观看历史", "我的上传"]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tabs.indices, id: \.self) { i in
                        Button {
                            tab = i
                        } label: {
                            Text(tabs[i])
                                .font(.system(size: 13.5, weight: tab == i ? .bold : .regular))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(tab == i ? Theme.text : Theme.surface2)
                                .foregroundColor(tab == i ? .black : Theme.sub)
                                .cornerRadius(99)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            content
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("我的片库")
        .task { await refreshSnapshots() }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case 0: gridFor(ids: library.favorites, empty: "还没有收藏, 看到喜欢的点「收藏」吧")
        case 1: authorsList
        case 2: gridFor(ids: library.watchLater, empty: "稍后看是空的")
        case 3: gridFor(ids: library.history, empty: "还没有观看记录", showProgress: true)
        default: WorksView(mineOnly: true, embedded: true)
        }
    }

    private func gridFor(ids: [String], empty: String, showProgress: Bool = false) -> some View {
        let items = ids.compactMap { refreshed[$0] ?? library.snapshots[$0] }
        return ScrollView {
            if items.isEmpty {
                Text(empty)
                    .foregroundColor(Theme.sub)
                    .padding(.top, 60)
            } else {
                VideoGrid(items: items, progressOf: showProgress ? { library.progress[$0.video_id] } : nil)
                    .padding(16)
            }
        }
    }

    private var authorsList: some View {
        ScrollView {
            VStack(spacing: 10) {
                if library.follows.isEmpty {
                    Text("还没关注作者, 在视频页点「+ 关注」")
                        .foregroundColor(Theme.sub)
                        .padding(.top, 60)
                }
                ForEach(library.follows, id: \.self) { a in
                    NavigationLink {
                        FeedView(author: a)
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(Theme.goldGradient)
                                Text(String(a.prefix(1))).font(.headline).foregroundColor(.black)
                            }
                            .frame(width: 42, height: 42)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("@" + a).font(.system(size: 15, weight: .bold))
                                Text("看 TA 的全部作品").font(.caption).foregroundColor(Theme.sub)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundColor(Theme.sub)
                        }
                        .padding(13)
                        .background(Theme.surface)
                        .cornerRadius(14)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }

    private func refreshSnapshots() async {
        let ids = Array(Set(library.favorites + library.watchLater + library.history))
        guard !ids.isEmpty else { return }
        for v in await FeedService.fetchByIds(ids) {
            refreshed[v.video_id] = v
        }
    }
}

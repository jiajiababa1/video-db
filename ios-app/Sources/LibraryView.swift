import SwiftUI

/// 片库: 收藏 / 关注作者 / 稍后看 / 历史 / 我的上传
struct LibraryView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var session: Session
    @State private var tab = 0
    @State private var refreshed: [String: VideoItem] = [:]

    private let tabs = ["收藏", "分组", "关注", "稍后看", "历史", "下载", "回收站", "上传"]
    @State private var showNewFolder = false

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
        case 1: foldersView
        case 2: authorsList
        case 3: gridFor(ids: library.watchLater, empty: "稍后看是空的")
        case 4: historyView
        case 5: DownloadsView(embedded: true)
        case 6: recycleView
        default: WorksView(mineOnly: true, embedded: true)
        }
    }

    private var historyView: some View {
        VStack(spacing: 0) {
            if !library.history.isEmpty {
                HStack {
                    Text("删除的历史会进回收站, 可恢复")
                        .font(.caption2).foregroundColor(Theme.sub)
                    Spacer()
                    Button("清空历史") { library.clearHistory() }
                        .font(.caption.weight(.bold)).foregroundColor(.red.opacity(0.85))
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
            }
            gridFor(ids: library.history, empty: "还没有观看记录", showProgress: true)
        }
    }

    private var foldersView: some View {
        ScrollView {
            VStack(spacing: 10) {
                Button {
                    showNewFolder = true
                } label: {
                    HStack {
                        Text("＋ 新建分组").font(.system(size: 14, weight: .bold))
                        Spacer()
                        Text("把收藏整理成组").font(.caption).foregroundColor(Theme.sub)
                    }
                    .padding(13).background(Theme.surface).cornerRadius(14)
                }
                .buttonStyle(.plain)
                if library.favFolders.isEmpty {
                    Text("还没有分组\n在视频卡片上长按 →「收藏到分组」也能把视频放进来")
                        .multilineTextAlignment(.center)
                        .foregroundColor(Theme.sub).padding(.top, 40)
                }
                ForEach(Array(library.favFolders.keys.sorted()), id: \.self) { name in
                    NavigationLink {
                        FeedView(personalIds: library.favFolders[name] ?? [], navTitle: name)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .foregroundColor(Theme.gold2).font(.system(size: 20))
                            Text(name).font(.system(size: 15, weight: .bold))
                            Spacer()
                            Text("\(library.favFolders[name]?.count ?? 0) 个")
                                .font(.caption).foregroundColor(Theme.sub)
                            Image(systemName: "chevron.right").foregroundColor(Theme.sub)
                        }
                        .padding(13).background(Theme.surface).cornerRadius(14)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("删除分组", role: .destructive) { library.deleteFolder(name) }
                    }
                }
            }
            .padding(16)
        }
        .sheet(isPresented: $showNewFolder) {
            NewFolderSheet()
        }
    }

    private var recycleView: some View {
        ScrollView {
            VStack(spacing: 10) {
                if library.recycle.isEmpty {
                    Text("回收站是空的")
                        .foregroundColor(Theme.sub).padding(.top, 60)
                } else {
                    HStack {
                        Text("共 \(library.recycle.count) 条").font(.caption).foregroundColor(Theme.sub)
                        Spacer()
                        Button("清空回收站") { library.purgeRecycle() }
                            .font(.caption.weight(.bold)).foregroundColor(.red.opacity(0.85))
                    }
                    ForEach(library.recycle) { e in
                        HStack(spacing: 11) {
                            CachedImage(urlString: e.item.thumbnail_url)
                                .frame(width: 96)
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .clipped().cornerRadius(9)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(e.item.displayTitle)
                                    .font(.system(size: 13)).lineLimit(2)
                                Text(e.kind == "fav" ? "来自收藏" : (e.kind == "wl" ? "来自稍后看" : "来自历史"))
                                    .font(.caption2).foregroundColor(Theme.sub)
                                Button("恢复") { library.restoreRecycle(e) }
                                    .font(.caption.weight(.bold)).foregroundColor(Theme.gold2)
                            }
                            Spacer()
                        }
                        .padding(10).background(Theme.surface).cornerRadius(14)
                    }
                }
            }
            .padding(16)
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
                        AuthorView(name: a)
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

/// 新建收藏分组
struct NewFolderSheet: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 14) {
                TextField("分组名, 如: 学习 / 收藏夹", text: $name)
                    .padding(.horizontal, 12).padding(.vertical, 11)
                    .background(Theme.surface2)
                    .cornerRadius(10)
                Button("创建") {
                    library.createFolder(name)
                    dismiss()
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.goldGradient)
                .foregroundColor(.black)
                .cornerRadius(12)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
            .padding(16)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("新建分组")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

import SwiftUI

/// 分享视频给朋友: 把站内视频以私信卡片 (MsgContent.share) 发给好友,
/// 对方在聊天里点卡片直接打开播放页。
/// 入口: 刷视频操作栏「分享」/ 视频卡与列表行长按菜单「分享给朋友」/ 好友列表里给好友挑视频。
enum VideoShare {
    static func send(_ video: VideoItem, to friend: String) async -> Bool {
        let c = MsgContent.share(id: video.video_id,
                                 title: video.displayTitle,
                                 thumb: video.thumbnail_url ?? "")
        return await DMAPI.send(token: Session.shared.loginToken,
                                to: friend, content: c.serialized)
    }

    static func acceptedFriends(me: String, rows: [FriendRow]) -> [String] {
        rows.filter { $0.status == "accepted" }
            .map { $0.user1 == me ? $0.user2 : $0.user1 }
            .sorted()
    }
}

/// 选朋友分享当前视频 (也保留系统分享入口)
struct ShareToFriendView: View {
    let video: VideoItem
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var friends: [String] = []
    @State private var sentTo: String? = nil
    @State private var failed = false
    @State private var showSystemShare = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("分享给好友")) {
                    if friends.isEmpty {
                        Text("还没有好友，先去加个好友吧")
                            .foregroundColor(.secondary)
                    }
                    ForEach(friends, id: \.self) { f in
                        Button {
                            Task { await share(f) }
                        } label: {
                            HStack {
                                Text("@" + f).foregroundColor(Theme.text)
                                Spacer()
                                if sentTo == f {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                } else {
                                    Image(systemName: "paperplane")
                                        .foregroundColor(Theme.gold2)
                                }
                            }
                        }
                    }
                }
                if failed {
                    Text("发送失败：登录可能已失效，重登后再试")
                        .font(.caption).foregroundColor(.red)
                }
                Section {
                    Button {
                        showSystemShare = true
                    } label: {
                        Label("系统分享（链接）", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .navigationTitle("分享视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(isPresented: $showSystemShare) {
                ActivityView(items: [URL(string: "https://jiajiababa1.github.io/video-db/watch.html?v=" + video.video_id)!])
            }
            .task {
                if let me = session.username {
                    friends = VideoShare.acceptedFriends(
                        me: me, rows: await SocialAPI.myFriendRows(me: me))
                }
            }
        }
    }

    private func share(_ f: String) async {
        if await VideoShare.send(video, to: f) {
            sentTo = f
            failed = false
        } else {
            failed = true
        }
    }
}

/// 在好友列表里给某个朋友挑视频分享: 来源 = 喜欢 / 历史 / 收藏
struct ShareVideoPickerView: View {
    let friend: String
    @EnvironmentObject var session: Session
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var items: [VideoItem] = []
    @State private var sentId: String? = nil
    @State private var failed = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("来源", selection: $tab) {
                    Text("喜欢").tag(0)
                    Text("历史").tag(1)
                    Text("收藏").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(10)
                List {
                    if items.isEmpty {
                        Text("这个来源暂时是空的")
                            .foregroundColor(.secondary)
                    }
                    ForEach(items) { v in
                        Button {
                            Task { await share(v) }
                        } label: {
                            HStack(spacing: 10) {
                                CachedImage(urlString: v.thumbnail_url)
                                    .frame(width: 64, height: 36)
                                    .cornerRadius(5)
                                Text(v.displayTitle)
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.text)
                                    .lineLimit(2)
                                Spacer()
                                if sentId == v.video_id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                } else {
                                    Image(systemName: "paperplane")
                                        .foregroundColor(Theme.gold2)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                if failed {
                    Text("发送失败：登录可能已失效，重登后再试")
                        .font(.caption).foregroundColor(.red)
                        .padding(.bottom, 6)
                }
            }
            .navigationTitle("分享给 @" + friend)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await reload() }
            .onChange(of: tab) { _ in Task { await reload() } }
        }
    }

    private func reload() async {
        switch tab {
        case 0:
            items = await FeedService.fetchByIds(await LikesAPI.myLikedIds())
        case 1:
            items = await FeedService.fetchByIds(library.history)
        default:
            items = await FeedService.fetchByIds(library.favorites)
        }
    }

    private func share(_ v: VideoItem) async {
        if await VideoShare.send(v, to: friend) {
            sentId = v.video_id
            failed = false
        } else {
            failed = true
        }
    }
}

/// 聊天里点开分享卡片: 按 video_id 取回视频并播放
struct SharedVideoPlayerSheet: View {
    let videoId: String
    @State private var item: VideoItem? = nil
    @State private var loaded = false

    var body: some View {
        Group {
            if let item = item {
                PlayerView(video: item)
            } else if loaded {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle).foregroundColor(Theme.sub)
                    Text("这个视频找不到了（可能已被删除）")
                        .foregroundColor(Theme.sub)
                }
            } else {
                ProgressView()
            }
        }
        .task {
            item = (await FeedService.fetchByIds([videoId])).first
            loaded = true
        }
    }
}

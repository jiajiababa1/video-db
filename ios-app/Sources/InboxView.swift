import SwiftUI

/// 「信息」页数据源行: my_notifications 聚合 (被赞/被评/好友申请)
struct NotifyRow: Decodable, Identifiable {
    var kind: String?
    var actor: String?
    var video_id: String?
    var video_title: String?
    var content: String?
    var created_at: String?

    var id: String {
        (kind ?? "") + "|" + (actor ?? "") + "|" + (video_id ?? "") + "|" + (created_at ?? "")
    }
    var timeText: String {
        guard let c = created_at else { return "" }
        return String(c.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }
}

/// 我发出的评论行: my_comments
struct MyCommentRow: Decodable, Identifiable {
    var video_id: String?
    var video_title: String?
    var content: String?
    var created_at: String?

    var id: String { (video_id ?? "") + "|" + (created_at ?? "") + "|" + (content ?? "") }
    var timeText: String {
        guard let c = created_at else { return "" }
        return String(c.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }
}

enum InboxAPI {
    static func notifications() async -> [NotifyRow] {
        let rows: [NotifyRow]? = try? await SB.rpc("my_notifications", params: [
            "p_token": Session.shared.loginToken, "p_limit": 50])
        return rows ?? []
    }

    static func myComments() async -> [MyCommentRow] {
        let rows: [MyCommentRow]? = try? await SB.rpc("my_comments", params: [
            "p_token": Session.shared.loginToken, "p_limit": 50])
        return rows ?? []
    }
}

/// 「信息」Tab: 通知(被赞/被评/好友申请) / 点赞(收到的+我赞过的) / 评论(收到的+我发出的) / 私信
struct InboxView: View {
    @EnvironmentObject var session: Session
    @State private var seg: Int
    @State private var notes: [NotifyRow] = []
    @State private var myComments: [MyCommentRow] = []
    @State private var likedVideos: [VideoItem] = []
    @State private var friendRows: [FriendRow] = []
    @State private var playItem: VideoItem? = nil
    @State private var loading = false

    init(initialSeg: Int = 0) {
        _seg = State(initialValue: initialSeg)
    }

    private var me: String { session.username ?? "" }
    private var likesReceived: [NotifyRow] { notes.filter { $0.kind == "like" } }
    private var commentsReceived: [NotifyRow] { notes.filter { $0.kind == "comment" } }
    private var acceptedFriends: [String] {
        friendRows.filter { $0.status == "accepted" }
            .map { $0.user1 == me ? $0.user2 : $0.user1 }
    }

    var body: some View {
        Group {
            if !session.isLoggedIn {
                VStack(spacing: 14) {
                    Image(systemName: "bell.slash").font(.largeTitle).foregroundColor(Theme.sub)
                    Text("登录后看你的点赞、评论和私信").foregroundColor(Theme.sub)
                    NavigationLink { AuthView() } label: {
                        Text("去登录").font(.system(size: 15, weight: .bold))
                            .padding(.horizontal, 26).padding(.vertical, 10)
                            .background(Theme.goldGradient).foregroundColor(.white)
                            .cornerRadius(99)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    Picker("信息", selection: $seg) {
                        Text("通知").tag(0)
                        Text("点赞").tag(1)
                        Text("评论").tag(2)
                        Text("私信").tag(3)
                    }
                    .pickerStyle(.segmented)
                    .padding(12)
                    List {
                        switch seg {
                        case 1: likeSections
                        case 2: commentSections
                        case 3: dmSections
                        default: noteSections
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("信息")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $playItem) { v in
            NavigationView { PlayerView(video: v) }
        }
    }

    // MARK: - 分段内容

    @ViewBuilder
    private var noteSections: some View {
        if notes.isEmpty {
            Text(loading ? "加载中…" : "暂无新通知")
                .foregroundColor(Theme.sub)
        }
        ForEach(notes) { n in
            noteRow(n)
        }
    }

    @ViewBuilder
    private var likeSections: some View {
        Section(header: Text("被点赞")) {
            if likesReceived.isEmpty {
                Text("暂无").foregroundColor(Theme.sub)
            }
            ForEach(likesReceived) { n in noteRow(n) }
        }
        Section(header: Text("我赞过的")) {
            if likedVideos.isEmpty {
                Text("暂无").foregroundColor(Theme.sub)
            }
            ForEach(likedVideos) { v in VideoRowLink(v: v) }
        }
    }

    @ViewBuilder
    private var commentSections: some View {
        Section(header: Text("被评论")) {
            if commentsReceived.isEmpty {
                Text("暂无").foregroundColor(Theme.sub)
            }
            ForEach(commentsReceived) { n in noteRow(n) }
        }
        Section(header: Text("我发出的评论")) {
            if myComments.isEmpty {
                Text("暂无").foregroundColor(Theme.sub)
            }
            ForEach(myComments) { c in
                Button { openVideo(c.video_id) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(c.video_title ?? "（作品）")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(Theme.text)
                            .lineLimit(1)
                        Text(c.content ?? "")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.sub)
                            .lineLimit(2)
                        Text(c.timeText)
                            .font(.caption2).foregroundColor(Theme.sub)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var dmSections: some View {
        if me != "kuo" {
            NavigationLink { ChatView(peer: "kuo") } label: {
                dmRow(name: "kuo", note: "联系站主")
            }
        }
        if acceptedFriends.isEmpty {
            Text("还没有好友, 去「朋友」里加好友后可私信")
                .foregroundColor(Theme.sub)
        }
        ForEach(acceptedFriends, id: \.self) { name in
            NavigationLink { ChatView(peer: name) } label: {
                dmRow(name: name, note: "私信")
            }
        }
    }

    private func dmRow(name: String, note: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.goldGradient)
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: 15, weight: .bold)).foregroundColor(.white)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 14.5, weight: .semibold)).foregroundColor(Theme.text)
                Text(note).font(.caption).foregroundColor(Theme.sub)
            }
        }
    }

    // MARK: - 通知行

    @ViewBuilder
    private func noteRow(_ n: NotifyRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName(n.kind))
                .font(.system(size: 15))
                .foregroundColor(iconColor(n.kind))
                .frame(width: 30, height: 30)
                .background(Theme.surface2)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(noteText(n))
                    .font(.system(size: 13.5))
                    .foregroundColor(Theme.text)
                    .lineLimit(2)
                if let t = n.video_title, !t.isEmpty, n.kind != "friend" {
                    Text("《" + t + "》")
                        .font(.caption).foregroundColor(Theme.sub).lineLimit(1)
                }
                Text(n.timeText).font(.caption2).foregroundColor(Theme.sub)
                if n.kind == "friend" {
                    HStack(spacing: 10) {
                        Button("通过") { Task { await actFriend(n, accept: true) } }
                            .font(.system(size: 12.5, weight: .bold))
                            .padding(.horizontal, 14).padding(.vertical, 5)
                            .background(Theme.goldGradient).foregroundColor(.white)
                            .cornerRadius(99)
                        Button("拒绝") { Task { await actFriend(n, accept: false) } }
                            .font(.system(size: 12.5))
                            .foregroundColor(Theme.sub)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if n.kind == "like" || n.kind == "comment" { openVideo(n.video_id) }
        }
    }

    private func iconName(_ kind: String?) -> String {
        switch kind {
        case "like": return "heart.fill"
        case "comment": return "text.bubble.fill"
        case "friend": return "person.badge.plus.fill"
        default: return "bell.fill"
        }
    }

    private func iconColor(_ kind: String?) -> Color {
        switch kind {
        case "like": return Color(red: 0.996, green: 0.173, blue: 0.333)
        case "comment": return Theme.gold2
        case "friend": return .green
        default: return Theme.sub
        }
    }

    private func noteText(_ n: NotifyRow) -> String {
        let actor = n.actor ?? "有人"
        switch n.kind {
        case "like": return "@" + actor + " 赞了你的视频"
        case "comment": return "@" + actor + " 评论: " + (n.content ?? "")
        case "friend": return "@" + actor + " 申请加你为好友"
        default: return "@" + actor
        }
    }

    // MARK: - 数据

    private func load() async {
        guard session.isLoggedIn else { return }
        loading = true
        notes = await InboxAPI.notifications()
        myComments = await InboxAPI.myComments()
        friendRows = await SocialAPI.myFriendRows(me: me)
        let ids = await LikesAPI.myLikedIds()
        var vids = await FeedService.fetchByIds(ids.filter { !$0.hasPrefix("work:") })
        let workIds = ids.filter { $0.hasPrefix("work:") }
        if !workIds.isEmpty {
            let works = await SocialAPI.works()
            let byId = Dictionary(uniqueKeysWithValues: works.map { ("work:" + String($0.id), $0.asVideoItem) })
            vids += workIds.compactMap { byId[$0] }
        }
        likedVideos = vids
        loading = false
    }

    private func openVideo(_ id: String?) {
        guard let id = id, !id.isEmpty else { return }
        Task {
            if id.hasPrefix("work:") {
                let works = await SocialAPI.works()
                if let w = works.first(where: { "work:" + String($0.id) == id }) {
                    playItem = w.asVideoItem
                }
            } else {
                playItem = await FeedService.fetchByIds([id]).first
            }
        }
    }

    private func actFriend(_ n: NotifyRow, accept: Bool) async {
        guard let actor = n.actor, !me.isEmpty else { return }
        if accept {
            await SocialAPI.accept(me: me, from: actor)
        } else {
            await SocialAPI.removeRow(a: actor, b: me)
        }
        await load()
        await NoticeCenter.shared.refresh(session: session)
    }
}

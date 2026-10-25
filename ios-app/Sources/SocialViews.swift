import SwiftUI

/// 好友页: 申请 / 添加 / 好友列表 + 社交入口 (群聊 / 作品墙)
struct FriendsView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var bridge: Bridge
    @State private var rows: [FriendRow] = []
    @State private var addName = ""
    @State private var note: String? = nil
    @State private var unread = 0

    private var me: String { session.username ?? "" }
    private var incoming: [FriendRow] { rows.filter { $0.status == "pending" && $0.user2 == me } }
    private var outgoing: [FriendRow] { rows.filter { $0.status == "pending" && $0.user1 == me } }
    private var friends: [FriendRow] { rows.filter { $0.status == "accepted" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if bridge.featureBoards {
                    entryRow(icon: "bubble.left.and.bubble.right.fill", title: "板块群聊",
                             sub: "进群聊天、找同好") { BoardsView() }
                }
                if bridge.featureWorks {
                    entryRow(icon: "photo.on.rectangle.angled", title: "作品墙",
                             sub: "大家上传的作品") { WorksView() }
                }
                if session.isLoggedIn {
                    entryRow(icon: "envelope.fill", title: "联系站主",
                             sub: unread > 0 ? "私信 · \(unread) 条未读" : "有问题直接私信站主") {
                        ChatView(peer: "kuo")
                    }
                }

                if !session.isLoggedIn {
                    Text("登录后可加好友、收申请 (在「我的」里登录)")
                        .font(.footnote).foregroundColor(Theme.sub)
                        .padding(.top, 8)
                } else {
                    addBox
                    if let n = note {
                        Text(n).font(.caption).foregroundColor(Theme.gold2)
                    }
                    if !incoming.isEmpty {
                        sectionTitle("新的申请 (\(incoming.count))")
                        ForEach(incoming, id: \.user1) { r in
                            personRow(name: r.user1, sub: "想加你为好友") {
                                HStack(spacing: 8) {
                                    Button("同意") { Task { await SocialAPI.accept(me: me, from: r.user1); await load() } }
                                        .font(.system(size: 13, weight: .bold))
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(Theme.goldGradient).foregroundColor(.black)
                                        .cornerRadius(99)
                                    Button("拒绝") { Task { await SocialAPI.removeRow(a: r.user1, b: me); await load() } }
                                        .font(.system(size: 13))
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(Theme.surface2).foregroundColor(Theme.sub)
                                        .cornerRadius(99)
                                }
                            }
                        }
                    }
                    sectionTitle("我的好友 (\(friends.count))")
                    if friends.isEmpty {
                        Text("还没有好友").font(.footnote).foregroundColor(Theme.sub)
                    }
                    ForEach(friends, id: \.created_at) { r in
                        let other = r.user1 == me ? r.user2 : r.user1
                        personRow(name: other, sub: "已是好友") {
                            HStack(spacing: 10) {
                                NavigationLink {
                                    ChatView(peer: other)
                                } label: {
                                    Text("私信")
                                        .font(.system(size: 13, weight: .bold))
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(Theme.goldGradient).foregroundColor(.black)
                                        .cornerRadius(99)
                                }
                                Button("删除") { Task { await SocialAPI.removeRow(a: me, b: other); await load() } }
                                    .font(.system(size: 13)).foregroundColor(.red)
                            }
                        }
                    }
                    if !outgoing.isEmpty {
                        sectionTitle("已发出的申请")
                        ForEach(outgoing, id: \.user2) { r in
                            personRow(name: r.user2, sub: "等待对方同意") { EmptyView() }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("好友与社交")
        .task { await load() }
        .refreshable { await load() }
    }

    private var addBox: some View {
        HStack(spacing: 8) {
            TextField("输入对方用户名", text: $addName)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.surface2)
                .cornerRadius(12)
            Button("添加") {
                Task { await add() }
            }
            .font(.system(size: 14, weight: .bold))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Theme.goldGradient).foregroundColor(.black)
            .cornerRadius(12)
        }
        .padding(.top, 6)
    }

    private func add() async {
        let name = addName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != me else { return }
        if await SocialAPI.userExists(name) {
            note = await SocialAPI.sendRequest(me: me, to: name) ? "已发送申请给 @" + name : "发送失败 (可能已申请过)"
            addName = ""
        } else {
            note = "没找到用户 @" + name
        }
        await load()
    }

    private func load() async {
        guard session.isLoggedIn else { return }
        rows = await SocialAPI.myFriendRows(me: me)
        unread = await DMAPI.unread(token: session.loginToken)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 16, weight: .bold)).padding(.top, 8)
    }

    private func entryRow<D: View>(icon: String, title: String, sub: String, @ViewBuilder dest: () -> D) -> some View {
        NavigationLink {
            dest()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                    .frame(width: 40, height: 40)
                    .background(Theme.goldGradient)
                    .foregroundColor(.black)
                    .cornerRadius(12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .bold))
                    Text(sub).font(.caption).foregroundColor(Theme.sub)
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

    private func personRow<T: View>(name: String, sub: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.surface2)
                Text(String(name.prefix(1))).font(.headline).foregroundColor(Theme.gold2)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text("@" + name).font(.system(size: 15, weight: .bold))
                Text(sub).font(.caption).foregroundColor(Theme.sub)
            }
            Spacer()
            trailing()
        }
        .padding(12)
        .background(Theme.surface)
        .cornerRadius(14)
    }
}

/// 板块群聊列表
struct BoardsView: View {
    @EnvironmentObject var session: Session
    @State private var groups: [BoardGroup] = []
    @State private var myGroups: Set<Int> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if groups.isEmpty {
                    Text("暂时没有开放的群")
                        .foregroundColor(Theme.sub).padding(.top, 60)
                }
                ForEach(groups) { g in
                    NavigationLink {
                        BoardChatView(group: g, isMember: myGroups.contains(g.id))
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12).fill(Theme.goldGradient)
                                Text(String((g.name ?? "群").prefix(1))).font(.headline).foregroundColor(.black)
                            }
                            .frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(g.name ?? "未命名群").font(.system(size: 15, weight: .bold))
                                Text(myGroups.contains(g.id) ? "已加入 · 点进聊天" : (g.entry_mode == "question" ? "答题入群" : "开放加入"))
                                    .font(.caption).foregroundColor(Theme.sub)
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
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("板块群聊")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        groups = await SocialAPI.activeGroups()
        if let me = session.username {
            myGroups = Set(await SocialAPI.myMemberships(me: me).map { $0.group_id })
        }
    }
}

/// 群聊窗口
struct BoardChatView: View {
    let group: BoardGroup
    @State var isMember: Bool
    @EnvironmentObject var session: Session
    @State private var msgs: [BoardMessage] = []
    @State private var draft = ""
    @State private var answer = ""
    @State private var note: String? = nil
    @State private var joinReqs: [SocialAPI.JoinReq] = []

    private var iAmGroupOwner: Bool {
        session.username != nil && group.owner == session.username
    }

    var body: some View {
        VStack(spacing: 0) {
            if iAmGroupOwner && !joinReqs.isEmpty {
                joinApprovalBar
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(msgs) { m in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("@" + (m.sender ?? "?"))
                                        .font(.caption.weight(.bold))
                                        .foregroundColor((m.sender ?? "") == session.username ? Theme.gold2 : Theme.sub)
                                    Text(m.timeText).font(.caption2).foregroundColor(Theme.sub)
                                }
                                Text(m.content ?? "")
                                    .font(.system(size: 14.5))
                                    .padding(.horizontal, 11).padding(.vertical, 8)
                                    .background((m.sender ?? "") == session.username ? Theme.surface2 : Theme.surface)
                                    .cornerRadius(12)
                            }
                            .id(m.id ?? 0)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: msgs.count) { _ in
                    if let last = msgs.last { proxy.scrollTo(last.id ?? 0, anchor: .bottom) }
                }
            }
            Divider().background(Theme.line)
            bottomBar
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(group.name ?? "群聊")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if !session.isLoggedIn {
            Text("登录后可进群聊天").font(.footnote).foregroundColor(Theme.sub).padding(14)
        } else if isMember {
            HStack(spacing: 8) {
                TextField("说点什么…", text: $draft)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Theme.surface2).cornerRadius(99)
                Button("发送") {
                    Task { await send() }
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Theme.gold2)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        } else if group.entry_mode == "question" {
            VStack(alignment: .leading, spacing: 8) {
                Text("入群问题: " + (group.entry_question ?? ""))
                    .font(.footnote)
                HStack(spacing: 8) {
                    TextField("你的答案", text: $answer)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Theme.surface2).cornerRadius(10)
                    Button("提交申请") {
                        Task {
                            if await SocialAPI.submitJoinRequest(groupId: group.id, me: session.username ?? "", answer: answer) {
                                note = "已提交, 等群主通过"
                            }
                        }
                    }
                    .font(.system(size: 13, weight: .bold)).foregroundColor(Theme.gold2)
                }
                if let n = note { Text(n).font(.caption).foregroundColor(Theme.gold2) }
            }
            .padding(12)
        } else {
            Button("加入群聊") {
                Task {
                    if await SocialAPI.joinOpen(groupId: group.id, me: session.username ?? "") {
                        isMember = true
                        await reload()
                    }
                }
            }
            .font(.system(size: 15, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Theme.goldGradient).foregroundColor(.black)
            .cornerRadius(12)
            .padding(12)
        }
    }

    private var joinApprovalBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("入群申请 (\(joinReqs.count))")
                .font(.system(size: 13.5, weight: .bold))
                .foregroundColor(Theme.gold2)
            ForEach(Array(joinReqs.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("@" + (r.applicant ?? "?")).font(.system(size: 13.5, weight: .bold))
                        if let a = r.answer, !a.isEmpty {
                            Text("答案: " + a).font(.caption).foregroundColor(Theme.sub)
                        }
                    }
                    Spacer()
                    Button("通过") {
                        Task {
                            await SocialAPI.approveJoin(groupId: group.id, applicant: r.applicant ?? "")
                            await reload()
                        }
                    }
                    .font(.system(size: 12.5, weight: .bold))
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(Theme.goldGradient).foregroundColor(.black)
                    .cornerRadius(99)
                    Button("拒绝") {
                        Task {
                            await SocialAPI.rejectJoin(groupId: group.id, applicant: r.applicant ?? "")
                            await reload()
                        }
                    }
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(Theme.surface2).foregroundColor(Theme.sub)
                    .cornerRadius(99)
                }
            }
        }
        .padding(12)
        .background(Theme.surface)
    }

    private func reload() async {
        msgs = await SocialAPI.messages(groupId: group.id)
        if iAmGroupOwner {
            joinReqs = await SocialAPI.pendingJoinRequests(groupId: group.id)
        }
    }

    private func send() async {
        guard let me = session.username else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        if await SocialAPI.sendMessage(groupId: group.id, sender: me, content: text) {
            await reload()
        }
    }
}

/// 作品墙
struct WorksView: View {
    var mineOnly: Bool = false
    var embedded: Bool = false
    @EnvironmentObject var session: Session
    @State private var works: [WorkItem] = []
    @State private var showSubmit = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                if works.isEmpty {
                    Text(mineOnly ? "你还没有上传的作品" : "作品墙还是空的")
                        .foregroundColor(Theme.sub).padding(.top, 60)
                }
                ForEach(works) { w in
                    workCard(w)
                }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(embedded ? "" : "作品墙")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if session.isLoggedIn && !embedded {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("投稿") { showSubmit = true }
                }
            }
        }
        .sheet(isPresented: $showSubmit, onDismiss: { Task { await load() } }) {
            WorkSubmitView()
        }
        .task { await load() }
    }

    private func workCard(_ w: WorkItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CachedImage(urlString: w.cover_url)
                .aspectRatio(16 / 9, contentMode: .fit)
            VStack(alignment: .leading, spacing: 4) {
                Text(w.title ?? "无标题").font(.system(size: 15, weight: .bold)).lineLimit(2)
                if let d = w.description, !d.isEmpty {
                    Text(d).font(.caption).foregroundColor(Theme.sub).lineLimit(2)
                }
                HStack {
                    Text("@" + (w.author ?? "")).font(.caption).foregroundColor(Theme.gold2)
                    Spacer()
                    if let f = w.file_url, let u = URL(string: f) {
                        Link("打开作品 ›", destination: u)
                            .font(.caption.weight(.bold)).foregroundColor(Theme.gold2)
                    }
                }
            }
            .padding(12)
        }
        .background(Theme.surface)
        .cornerRadius(Theme.cardRadius)
    }

    private func load() async {
        var all = await SocialAPI.works()
        if mineOnly {
            let me = session.username ?? ""
            all = all.filter { $0.author == me }
        }
        works = all
    }
}

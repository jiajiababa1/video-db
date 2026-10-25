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

    @State private var showCreate = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if session.isLoggedIn {
                    Button {
                        showCreate = true
                    } label: {
                        HStack {
                            Text("＋ 创建群聊").font(.system(size: 14, weight: .bold))
                            Spacer()
                            Text("建自己的群").font(.caption).foregroundColor(Theme.sub)
                        }
                        .padding(13)
                        .background(Theme.surface)
                        .cornerRadius(14)
                    }
                    .buttonStyle(.plain)
                }
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
        .sheet(isPresented: $showCreate, onDismiss: { Task { await load() } }) {
            CreateGroupView()
        }
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
    @State private var answer = ""
    @State private var note: String? = nil
    @State private var joinReqs: [SocialAPI.JoinReq] = []
    @State private var myRole: String = "member"
    @State private var myMutedUntil: String? = nil
    @State private var showManage = false

    private var iAmGroupOwner: Bool {
        session.username != nil && group.owner == session.username
    }

    private var canManage: Bool {
        session.isOwner || iAmGroupOwner || myRole == "owner" || myRole == "admin"
    }

    private var mutedNow: Bool {
        if let u = myMutedUntil, let d = ISO8601.date(u), d > Date() { return true }
        if group.mute_all == true && myRole == "member" && !iAmGroupOwner && !session.isOwner { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            if iAmGroupOwner && !joinReqs.isEmpty {
                joinApprovalBar
            }
            if isMember && session.isLoggedIn {
                HStack(spacing: 10) {
                    if canManage {
                        Button("👥 群管理") { showManage = true }
                            .font(.system(size: 12.5, weight: .bold)).foregroundColor(Theme.gold2)
                    }
                    Spacer()
                    if group.mute_all == true {
                        Text("🔇 全员禁言中").font(.caption2).foregroundColor(Theme.sub)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Theme.surface)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(msgs) { m in
                            boardBubble(m)
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
        .sheet(isPresented: $showManage) {
            GroupManageView(group: group, myRole: myRole)
        }
        .task { await reload() }
    }

    private func boardBubble(_ m: BoardMessage) -> some View {
        let mine = (m.sender ?? "") == session.username
        return HStack {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if !mine {
                        Text("@" + (m.sender ?? "?"))
                            .font(.caption.weight(.bold)).foregroundColor(Theme.sub)
                    }
                    Text(m.timeText).font(.caption2).foregroundColor(Theme.sub)
                }
                MessageBubble(content: MsgContent.parse(m.content ?? ""), isMe: mine)
            }
            if !mine { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if !session.isLoggedIn {
            Text("登录后可进群聊天").font(.footnote).foregroundColor(Theme.sub).padding(14)
        } else if isMember {
            if mutedNow {
                Text("🔇 你已被禁言, 暂时不能发言")
                    .font(.footnote).foregroundColor(Theme.sub).padding(14)
            } else {
                ChatSendBar { content in
                    Task { await send(content) }
                }
            }
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
        if let me = session.username, isMember,
           let detail = await SocialAPI.memberDetail(groupId: group.id, me: me) {
            myRole = detail.role ?? "member"
            myMutedUntil = detail.muted_until
        }
    }

    private func send(_ content: MsgContent) async {
        guard let me = session.username else { return }
        if await SocialAPI.sendMessage(groupId: group.id, sender: me, content: content.serialized) {
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
    @State private var playURL: IdentifiedString? = nil
    @State private var viewImage: IdentifiedString? = nil

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                if session.isLoggedIn && !embedded {
                    HStack {
                        Spacer()
                        Button { showSubmit = true } label: {
                            Text("＋ 投稿").font(.caption.weight(.bold))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Theme.goldGradient).foregroundColor(.black)
                                .cornerRadius(14)
                        }
                    }
                }
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
        .sheet(isPresented: $showSubmit, onDismiss: { Task { await load() } }) {
            WorkSubmitView()
        }
        .sheet(item: $playURL) { w in
            SimpleVideoPlayer(urlString: w.value)
        }
        .sheet(item: $viewImage) { w in
            ZStack {
                Color.black.ignoresSafeArea()
                CachedImage(urlString: w.value).scaledToFit()
            }
        }
        .task { await load() }
    }

    private enum WorkKind { case video, image, other }

    private func kind(of url: String) -> WorkKind {
        let u = url.lowercased()
        if u.contains(".mp4") || u.contains(".mov") || u.contains(".m4v") || u.contains(".webm") || u.contains("video.twimg.com") {
            return .video
        }
        if u.contains(".jpg") || u.contains(".jpeg") || u.contains(".png") || u.contains(".webp") || u.contains(".gif") {
            return .image
        }
        return .other
    }

    private func openWork(_ w: WorkItem) {
        guard let f = w.file_url, !f.isEmpty else { return }
        switch kind(of: f) {
        case .video: playURL = IdentifiedString(value: f)
        case .image: viewImage = IdentifiedString(value: f)
        case .other:
            if let u = URL(string: f) { UIApplication.shared.open(u) }
        }
    }

    private func workCard(_ w: WorkItem) -> some View {
        let k = kind(of: w.file_url ?? "")
        return VStack(alignment: .leading, spacing: 0) {
            ZStack {
                CachedImage(urlString: w.cover_url)
                    .aspectRatio(16 / 9, contentMode: .fit)
                if k == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 40)).foregroundColor(.white.opacity(0.92))
                        .shadow(radius: 4)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { openWork(w) }
            VStack(alignment: .leading, spacing: 4) {
                Text(w.title ?? "无标题").font(.system(size: 15, weight: .bold)).lineLimit(2)
                if let d = w.description, !d.isEmpty {
                    Text(d).font(.caption).foregroundColor(Theme.sub).lineLimit(2)
                }
                HStack {
                    Text("@" + (w.author ?? "")).font(.caption).foregroundColor(Theme.gold2)
                    Spacer()
                    Button(k == .video ? "▶ 播放" : (k == .image ? "查看图片" : "打开作品 ›")) {
                        openWork(w)
                    }
                    .font(.caption.weight(.bold)).foregroundColor(Theme.gold2)
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

/// 建群
struct CreateGroupView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var mode = "open"
    @State private var question = ""
    @State private var note: String? = nil
    @State private var busy = false

    var body: some View {
        NavigationView {
            Form {
                Section("群名称") {
                    TextField("给群起个名字", text: $name)
                }
                Section("入群方式") {
                    Picker("方式", selection: $mode) {
                        Text("开放加入").tag("open")
                        Text("答题入群").tag("question")
                    }
                    .pickerStyle(.segmented)
                    if mode == "question" {
                        TextField("入群问题 (如: 群规是什么?)", text: $question)
                    }
                }
                if let n = note {
                    Text(n).font(.caption).foregroundColor(Theme.gold2)
                }
                Button(busy ? "创建中…" : "创建群聊") {
                    Task { await create() }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
            .navigationTitle("创建群聊")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func create() async {
        guard let me = session.username else { return }
        busy = true
        let ok = await SocialAPI.createGroup(
            name: name.trimmingCharacters(in: .whitespaces), owner: me,
            mode: mode, question: question.trimmingCharacters(in: .whitespaces))
        busy = false
        if ok { dismiss() } else { note = "创建失败, 稍后再试" }
    }
}

/// 群管理 (群主/管理员/站长): 成员禁言/踢人/设管理员 + 全员禁言 + 解散
struct GroupManageView: View {
    let group: BoardGroup
    var myRole: String
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var members: [BoardMember] = []
    @State private var muteAll: Bool = false
    @State private var confirmDissolve = false

    private var iAmOwner: Bool {
        session.isOwner || group.owner == session.username || myRole == "owner"
    }

    var body: some View {
        NavigationView {
            List {
                if iAmOwner {
                    Section("群设置") {
                        Toggle("全员禁言", isOn: $muteAll)
                            .onChange(of: muteAll) { v in
                                Task { await SocialAPI.setMuteAll(groupId: group.id, on: v) }
                            }
                        Button("解散群聊", role: .destructive) { confirmDissolve = true }
                    }
                }
                Section("成员 (\(members.count))") {
                    ForEach(Array(members.enumerated()), id: \.offset) { _, m in
                        memberRow(m)
                    }
                }
            }
            .navigationTitle("群管理")
            .navigationBarTitleDisplayMode(.inline)
            .alert("解散群聊?", isPresented: $confirmDissolve) {
                Button("解散", role: .destructive) {
                    Task {
                        await SocialAPI.dissolve(groupId: group.id)
                        dismiss()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("解散后群将从列表消失, 成员无法继续聊天。")
            }
            .task {
                muteAll = group.mute_all ?? false
                await load()
            }
        }
    }

    private func memberRow(_ m: BoardMember) -> some View {
        let isSelf = m.username == session.username
        let muted = m.muted_until.flatMap { ISO8601.date($0) }.map { $0 > Date() } ?? false
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("@" + m.username).font(.system(size: 14, weight: .bold))
                    if m.role == "owner" {
                        Text("群主").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.gold).foregroundColor(.black).cornerRadius(6)
                    } else if m.role == "admin" {
                        Text("管理员").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.surface2).foregroundColor(Theme.sub).cornerRadius(6)
                    }
                    if muted { Text("禁言中").font(.caption2).foregroundColor(.red) }
                }
                if let u = m.muted_until, muted {
                    Text("解禁: " + String(u.prefix(16)).replacingOccurrences(of: "T", with: " "))
                        .font(.caption2).foregroundColor(Theme.sub)
                }
            }
            Spacer()
            if !isSelf && m.role != "owner" {
                Menu {
                    Button("禁言 1 小时") { Task { await mute(m, hours: 1) } }
                    Button("禁言 24 小时") { Task { await mute(m, hours: 24) } }
                    if muted { Button("解除禁言") { Task { await unmute(m) } } }
                    if iAmOwner {
                        if m.role == "admin" {
                            Button("取消管理员") { Task { await setRole(m, "member") } }
                        } else {
                            Button("设为管理员") { Task { await setRole(m, "admin") } }
                        }
                    }
                    Button("踢出群聊", role: .destructive) { Task { await kick(m) } }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20)).foregroundColor(Theme.gold2)
                }
            }
        }
    }

    private func load() async {
        members = await SocialAPI.groupMembers(groupId: group.id)
    }

    private func mute(_ m: BoardMember, hours: Double) async {
        let until = ISO8601DateFormatter().string(from: Date().addingTimeInterval(hours * 3600))
        await SocialAPI.setMuted(groupId: group.id, user: m.username, until: until)
        await load()
    }

    private func unmute(_ m: BoardMember) async {
        await SocialAPI.setMuted(groupId: group.id, user: m.username, until: nil)
        await load()
    }

    private func kick(_ m: BoardMember) async {
        await SocialAPI.kick(groupId: group.id, user: m.username)
        await load()
    }

    private func setRole(_ m: BoardMember, _ role: String) async {
        await SocialAPI.setRole(groupId: group.id, user: m.username, role: role)
        await load()
    }
}

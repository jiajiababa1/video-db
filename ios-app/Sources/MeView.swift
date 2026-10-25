import SwiftUI

/// 我的: 账号 / 数据主页 / 云同步 / 站长工具 / 数据管理
struct MeView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var library: Library
    @EnvironmentObject var bridge: Bridge
    @State private var totalVideos: Int? = nil
    @State private var lastRun: String? = nil
    @State private var savedLastRun: Int? = nil
    @State private var showAuth = false
    @State private var showClearConfirm = false
    @State private var syncNote: String? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                accountCard
                statsCard
                if session.isLoggedIn {
                    syncCard
                    accountSettingsCard
                }
                if session.isOwner {
                    ownerCard
                }
                hotUpdateCard
                filterCard
                moreCard
                dataCard
                Text("2048 影院 · 原生版 v1.3")
                    .font(.caption2).foregroundColor(Theme.sub)
                    .padding(.top, 6)
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("我的")
        .task { await loadStats() }
        .sheet(isPresented: $showAuth) { AuthView() }
    }

    // MARK: 账号
    private var accountCard: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().fill(Theme.goldGradient)
                Text(session.isLoggedIn ? String((session.username ?? "?").prefix(1)) : "?")
                    .font(.system(size: 22, weight: .heavy)).foregroundColor(.black)
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.isLoggedIn ? "@" + (session.username ?? "") : "未登录")
                    .font(.system(size: 17, weight: .bold))
                Text(session.isLoggedIn
                     ? (session.isAdmin ? "站主账号" : (session.vipLevel > 0 ? "VIP \(session.vipLevel)" : "普通账号"))
                     : "登录后可评论、加好友、云同步")
                    .font(.caption).foregroundColor(Theme.sub)
            }
            Spacer()
            if session.isLoggedIn {
                Button("退出") { session.logout() }
                    .font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Theme.surface2).foregroundColor(Theme.text)
                    .cornerRadius(99)
            } else {
                Button("登录") { showAuth = true }
                    .font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Theme.goldGradient).foregroundColor(.black)
                    .cornerRadius(99)
            }
        }
        .padding(15)
        .background(Theme.surface)
        .cornerRadius(18)
    }

    // MARK: 数据主页
    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("数据主页").font(.system(size: 16, weight: .bold))
            HStack(spacing: 10) {
                statBox("全站视频", totalVideos.map { String($0) } ?? "—")
                statBox("我的收藏", String(library.favorites.count))
                statBox("观看历史", String(library.history.count))
            }
            if let lr = lastRun {
                Text("爬虫上次运行: \(lr)" + (savedLastRun.map { " · 入库 \($0) 条" } ?? ""))
                    .font(.caption).foregroundColor(Theme.sub)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(Theme.surface)
        .cornerRadius(18)
    }

    private func statBox(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 19, weight: .heavy)).foregroundColor(Theme.gold2)
            Text(label).font(.caption2).foregroundColor(Theme.sub)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Theme.surface2)
        .cornerRadius(12)
    }

    // MARK: 云同步
    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("云同步").font(.system(size: 16, weight: .bold))
            Text("收藏 / 稍后看 / 历史 与网站互通")
                .font(.caption).foregroundColor(Theme.sub)
            if let n = syncNote {
                Text(n).font(.caption).foregroundColor(Theme.gold2)
            }
            Button("立即同步") {
                Task {
                    syncNote = "同步中…"
                    await CloudSync.pullMerge(into: library, session: session)
                    syncNote = "同步完成 ✓"
                }
            }
            .font(.system(size: 14, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Theme.goldGradient).foregroundColor(.black)
            .cornerRadius(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(Theme.surface)
        .cornerRadius(18)
    }

    // MARK: 账号设置 (改密码 / 兑换码)
    @State private var oldPass = ""
    @State private var newPass = ""
    @State private var redeemInput = ""
    @State private var accountNote: String? = nil

    private var accountSettingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("账号设置").font(.system(size: 16, weight: .bold))
            SecureField("旧密码", text: $oldPass)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.surface2).cornerRadius(10)
            SecureField("新密码", text: $newPass)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.surface2).cornerRadius(10)
            Button("修改密码") {
                Task {
                    guard let me = session.username else { return }
                    let r = await AccountAPI.changePassword(user: me, old: oldPass, new: newPass)
                    if r.ok {
                        accountNote = "密码已修改, 请重新登录"
                        session.logout()
                    } else {
                        accountNote = r.msg
                    }
                }
            }
            .font(.system(size: 13.5, weight: .bold))
            .disabled(oldPass.isEmpty || newPass.count < 4)
            Divider().background(Theme.line)
            HStack(spacing: 8) {
                TextField("VIP 兑换码", text: $redeemInput)
                    .autocapitalization(.allCharacters)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Theme.surface2).cornerRadius(10)
                Button("兑换") {
                    Task {
                        guard let me = session.username else { return }
                        let r = await AccountAPI.redeem(user: me, code: redeemInput)
                        accountNote = r.msg
                        if r.ok { redeemInput = "" }
                    }
                }
                .font(.system(size: 13.5, weight: .bold))
                .foregroundColor(Theme.gold2)
                .disabled(redeemInput.isEmpty)
            }
            if let n = accountNote {
                Text(n).font(.caption).foregroundColor(Theme.gold2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(Theme.surface)
        .cornerRadius(18)
    }

    // MARK: 内容过滤 (屏蔽词 / 隐藏 / 屏蔽作者, 与账号云同步)
    @State private var badwordDraft = ""

    private var filterCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("内容过滤").font(.system(size: 16, weight: .bold))
            Text("屏蔽词 (标题含这些词的视频不显示)")
                .font(.caption).foregroundColor(Theme.sub)
            HStack(spacing: 8) {
                TextField("输入屏蔽词", text: $badwordDraft)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Theme.surface2).cornerRadius(9)
                Button("添加") {
                    library.addBadword(badwordDraft)
                    badwordDraft = ""
                }
                .font(.system(size: 13, weight: .bold)).foregroundColor(Theme.gold2)
                .disabled(badwordDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !library.badwords.isEmpty {
                FlowChips(items: library.badwords) { w in library.removeBadword(w) }
            }
            if !library.hiddenIds.isEmpty {
                Text("已隐藏视频 (\(library.hiddenIds.count))")
                    .font(.caption).foregroundColor(Theme.sub)
                ForEach(library.hiddenIds, id: \.self) { id in
                    HStack(spacing: 8) {
                        Text(library.snapshots[id]?.displayTitle ?? id)
                            .font(.caption).lineLimit(1)
                        Spacer()
                        Button("取消隐藏") {
                            if let v = library.snapshots[id] { library.toggleHidden(v) }
                        }
                        .font(.caption.weight(.bold)).foregroundColor(Theme.gold2)
                    }
                }
            }
            if !library.blockedAuthors.isEmpty {
                Text("已屏蔽作者 (\(library.blockedAuthors.count))")
                    .font(.caption).foregroundColor(Theme.sub)
                ForEach(library.blockedAuthors, id: \.self) { a in
                    HStack(spacing: 8) {
                        Text("@" + a).font(.caption).lineLimit(1)
                        Spacer()
                        Button("解除屏蔽") { library.toggleBlock(a) }
                            .font(.caption.weight(.bold)).foregroundColor(Theme.gold2)
                    }
                }
            }
            if library.badwords.isEmpty && library.hiddenIds.isEmpty && library.blockedAuthors.isEmpty {
                Text("暂无过滤项。在视频卡片上长按可以屏蔽作者、隐藏视频。")
                    .font(.caption).foregroundColor(Theme.sub)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(Theme.surface)
        .cornerRadius(18)
    }

    // MARK: 站长工具
    @State private var ghDraft = ""
    @State private var sbDraft = ""
    @State private var scrapeNote: String? = nil
    @State private var scrapeBusy = false
    @State private var scrapeProgress: Double? = nil

    private var ownerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("站长工具").font(.system(size: 16, weight: .bold))
            SecureField("GitHub 令牌 (gh_token)", text: $ghDraft)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.surface2).cornerRadius(10)
                .onAppear { ghDraft = session.ghToken }
                .onChange(of: ghDraft) {
                    session.ghToken = $0
                    Task { await TokenVault.pushTokens(session: session) }
                }
            SecureField("数据库令牌 (sb_token)", text: $sbDraft)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.surface2).cornerRadius(10)
                .onAppear { sbDraft = session.sbToken }
                .onChange(of: sbDraft) {
                    session.sbToken = $0
                    Task { await TokenVault.pushTokens(session: session) }
                }
            Text("令牌加密后跟账号云同步, 登录自动取回, 与网站互通")
                .font(.caption2).foregroundColor(Theme.sub)
            HStack(spacing: 8) {
                ownerBtn("全量抓取", mode: "full")
                ownerBtn("解析补链", mode: "resolve")
                ownerBtn("抓 Hsex", mode: "hsex")
            }
            if let p = scrapeProgress {
                ProgressView(value: p).tint(Theme.gold)
            }
            if let n = scrapeNote {
                Text(n).font(.caption).foregroundColor(Theme.sub)
            }
            Divider().background(Theme.line)
            HStack {
                Text("待审作品 (\(pendingWorks.count))")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Button("刷新") { Task { await loadPendingWorks() } }
                    .font(.caption.weight(.bold)).foregroundColor(Theme.gold2)
            }
            if pendingWorks.isEmpty {
                Text("暂无待审核投稿")
                    .font(.caption).foregroundColor(Theme.sub)
            }
            ForEach(pendingWorks) { w in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(w.title ?? "无标题")
                            .font(.system(size: 13.5, weight: .bold)).lineLimit(1)
                        Spacer()
                        Text("@" + (w.submitter ?? ""))
                            .font(.caption2).foregroundColor(Theme.sub)
                    }
                    if let d = w.description, !d.isEmpty {
                        Text(d).font(.caption).foregroundColor(Theme.sub).lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        Button("✅ 通过入库") {
                            Task {
                                await SocialAPI.approveWork(w)
                                await loadPendingWorks()
                            }
                        }
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.goldGradient).foregroundColor(.black)
                        .cornerRadius(99)
                        Button("拒绝") {
                            Task {
                                await SocialAPI.rejectWork(id: w.id)
                                await loadPendingWorks()
                            }
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.surface2).foregroundColor(Theme.sub)
                        .cornerRadius(99)
                    }
                }
                .padding(10)
                .background(Theme.surface2)
                .cornerRadius(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(Theme.surface)
        .cornerRadius(18)
        .task { await loadPendingWorks() }
    }

    @State private var pendingWorks: [SocialAPI.WorkRequest] = []

    private func loadPendingWorks() async {
        guard session.isOwner else { return }
        pendingWorks = await SocialAPI.pendingWorks()
    }

    private func ownerBtn(_ title: String, mode: String) -> some View {
        Button(title) {
            Task { await runScrape(mode: mode) }
        }
        .font(.system(size: 13, weight: .bold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Theme.surface2).foregroundColor(Theme.text)
        .cornerRadius(10)
        .disabled(scrapeBusy)
    }

    private func runScrape(mode: String) async {
        let token = session.ghToken
        guard !token.isEmpty else { scrapeNote = "先填 GitHub 令牌"; return }
        scrapeBusy = true
        scrapeNote = "正在触发…"
        let ok = await GitHub.dispatch(mode: mode, token: token)
        if !ok {
            scrapeNote = "触发失败, 检查令牌"
            scrapeBusy = false
            return
        }
        scrapeNote = "云端运行中…"
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            if let st = await GitHub.latestRunState(token: token) {
                scrapeProgress = st.progress
                if st.status == "completed" {
                    scrapeNote = st.conclusion == "success" ? "运行完成 ✓" : "运行结束: \(st.conclusion ?? "")"
                    break
                }
            }
        }
        scrapeBusy = false
        await loadStats()
    }

    // MARK: 热更新
    @State private var bridgeOn = true

    private var hotUpdateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("热更新").font(.system(size: 16, weight: .bold))
            infoRow("更新包版本", bridge.bundleVersion > 0 ? "v\(bridge.bundleVersion)" : "内置 (无远程包)")
            infoRow("插件状态", bridge.pluginVersion.map { "LiveContainer 插件 v\($0) ✓" } ?? "未挂插件 (App 自行更新)")
            infoRow("链路自检", bridge.helloRan ? "JS 模块引擎正常 ✓" : "等待首个模块运行")
            if !bridge.moduleNames.isEmpty {
                infoRow("已加载模块", bridge.moduleNames.joined(separator: " · "))
            }
            infoRow("状态", bridge.statusText)
            HStack(spacing: 8) {
                Button("检查更新") {
                    Task { await bridge.checkUpdate(manual: true) }
                }
                .font(.system(size: 13, weight: .bold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Theme.goldGradient).foregroundColor(.black)
                .cornerRadius(99)
                Button("回滚一版") { bridge.rollback() }
                    .font(.system(size: 13))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Theme.surface2).foregroundColor(Theme.text)
                    .cornerRadius(99)
            }
            Toggle("启用远程更新", isOn: $bridgeOn)
                .font(.system(size: 14))
                .tint(Theme.gold)
                .onAppear { bridgeOn = bridge.enabled }
                .onChange(of: bridgeOn) { bridge.enabled = $0 }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(Theme.surface)
        .cornerRadius(18)
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.caption).foregroundColor(Theme.sub).frame(width: 76, alignment: .leading)
            Text(v).font(.caption).foregroundColor(Theme.text)
            Spacer()
        }
    }

    // MARK: 更多 (站内页面 / 屏蔽管理)
    private var moreCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("更多").font(.system(size: 16, weight: .bold))
            NavigationLink {
                SitePageView(slug: "about", fallbackTitle: "关于")
            } label: {
                moreRow("关于本站", icon: "info.circle")
            }
            Divider().background(Theme.line)
            NavigationLink {
                SitePageView(slug: "contact", fallbackTitle: "联系站主")
            } label: {
                moreRow("联系站主", icon: "envelope")
            }
            if !library.blockedAuthors.isEmpty {
                Divider().background(Theme.line)
                Text("已屏蔽的作者").font(.caption).foregroundColor(Theme.sub)
                ForEach(library.blockedAuthors, id: \.self) { a in
                    HStack {
                        Text("@" + a).font(.system(size: 14))
                        Spacer()
                        Button("取消屏蔽") { library.toggleBlock(a) }
                            .font(.system(size: 12.5)).foregroundColor(Theme.gold2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(Theme.surface)
        .cornerRadius(18)
    }

    private func moreRow(_ title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(Theme.gold2)
            Text(title).font(.system(size: 14.5)).foregroundColor(Theme.text)
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundColor(Theme.sub)
        }
    }

    // MARK: 数据管理
    private var dataCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("数据管理").font(.system(size: 16, weight: .bold))
            Button("清空观看历史") { library.clearHistory() }
                .font(.system(size: 14))
                .foregroundColor(Theme.text)
            Divider().background(Theme.line)
            Button("清空全部本地数据") { showClearConfirm = true }
                .font(.system(size: 14))
                .foregroundColor(.red)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(Theme.surface)
        .cornerRadius(18)
        .confirmationDialog("清空收藏、稍后看、历史、关注?", isPresented: $showClearConfirm) {
            Button("全部清空", role: .destructive) { library.clearAll() }
            Button("取消", role: .cancel) {}
        }
    }

    private func loadStats() async {
        totalVideos = await FeedService.totalCount()
        struct SR: Decodable { var last_run: String?; var videos_saved: FlexInt? }
        let url = SB.base.absoluteString + "/rest/v1/scrape_status?select=last_run,videos_saved&order=last_run.desc&limit=1"
        let (rows, _): ([SR], Int?) = (try? await SB.getRaw(url)) ?? ([], nil)
        if let r = rows.first {
            lastRun = r.last_run.map { String($0.prefix(16)).replacingOccurrences(of: "T", with: " ") }
            savedLastRun = r.videos_saved?.value
        }
    }
}

/// 登录页 (注册需图形验证码, 引导去网站注册)
struct AuthView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var user = ""
    @State private var pass = ""
    @State private var error: String? = nil
    @State private var busy = false

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Text("登录账号")
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundStyle(Theme.goldGradient)
                    .padding(.top, 30)
                TextField("用户名", text: $user)
                    .autocapitalization(.none)
                    .padding(.horizontal, 13).padding(.vertical, 12)
                    .background(Theme.surface2).cornerRadius(12)
                SecureField("密码", text: $pass)
                    .padding(.horizontal, 13).padding(.vertical, 12)
                    .background(Theme.surface2).cornerRadius(12)
                if let e = error {
                    Text(e).foregroundColor(.red).font(.footnote)
                }
                Button {
                    Task { await submit() }
                } label: {
                    Text(busy ? "登录中…" : "登录")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Theme.goldGradient)
                        .foregroundColor(.black)
                        .cornerRadius(12)
                }
                .disabled(busy || user.isEmpty || pass.isEmpty)
                Text("还没有账号? 注册需图形验证码, 请在网站上注册后再回这里登录")
                    .font(.caption).foregroundColor(Theme.sub)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding(20)
            .background(Theme.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func submit() async {
        busy = true
        error = await session.login(username: user, password: pass)
        busy = false
        if error == nil { dismiss() }
    }
}

/// 可删除的词条 chips (单行横滑)
struct FlowChips: View {
    let items: [String]
    var onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(items, id: \.self) { w in
                    HStack(spacing: 5) {
                        Text(w).font(.system(size: 12.5))
                        Button {
                            onRemove(w)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12)).foregroundColor(Theme.sub)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.surface2)
                    .cornerRadius(99)
                }
            }
        }
    }
}

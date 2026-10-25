import SwiftUI

/// 我的: 账号 / 数据主页 / 云同步 / 站长工具 / 数据管理
struct MeView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var library: Library
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
                }
                if session.isOwner {
                    ownerCard
                }
                dataCard
                Text("2048 影院 · 原生版 v1.0")
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

    // MARK: 站长工具
    @State private var ghDraft = ""
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
                .onChange(of: ghDraft) { session.ghToken = $0 }
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(Theme.surface)
        .cornerRadius(18)
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
        struct SR: Decodable { var last_run: String?; var videos_saved: Int? }
        let url = SB.base.absoluteString + "/rest/v1/scrape_status?select=last_run,videos_saved&order=last_run.desc&limit=1"
        let (rows, _): ([SR], Int?) = (try? await SB.getRaw(url)) ?? ([], nil)
        if let r = rows.first {
            lastRun = r.last_run.map { String($0.prefix(16)).replacingOccurrences(of: "T", with: " ") }
            savedLastRun = r.videos_saved
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

import SwiftUI

// MARK: - 用户管理

struct AdminUsersView: View {
    @State private var q = ""
    @State private var rows: [[String: Any]] = []
    @State private var selected: [String: Any]? = nil
    @State private var showEditor = false

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("搜用户名（空=最近注册）", text: $q).autocorrectionDisabled()
                    Button("查询") { Task { await load() } }
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                Button {
                    selected = r
                    showEditor = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("@" + adminStr(r, "username")).foregroundColor(.primary)
                            Text(String(adminStr(r, "created_at").prefix(10)) + " 注册")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        if adminBool(r, "banned") { badge("已封禁", .red) }
                        if adminBool(r, "is_admin") { badge("管理员", .blue) }
                        if adminBool(r, "verified") { badge("已认证", .teal) }
                        let vip = adminStr(r, "vip_level")
                        if !vip.isEmpty && vip != "0" { badge("VIP " + vip, .orange) }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("用户管理")
        .task { await load() }
        .sheet(isPresented: $showEditor) {
            if let u = selected { AdminUserEditor(user: u) { Task { await load() } } }
        }
    }

    private func badge(_ t: String, _ c: Color) -> some View {
        Text(t).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
            .background(c.opacity(0.18)).foregroundColor(c).cornerRadius(6)
    }

    private func load() async {
        var query = [
            URLQueryItem(name: "select", value: "username,vip_level,vip_expires_at,is_admin,verified,banned,created_at"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "100"),
        ]
        let kw = q.trimmingCharacters(in: .whitespaces)
        if !kw.isEmpty { query.append(URLQueryItem(name: "username", value: "ilike.*" + kw + "*")) }
        rows = await AdminAPI.restRows("rest/v1/user_accounts", query: query)
    }
}

struct AdminUserEditor: View {
    let user: [String: Any]
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var vipLevel = "vip"
    @State private var vipMinutes = 43200
    @State private var vipPerm = false
    @State private var banReason = ""
    @State private var newPwd = ""
    @State private var confirmDelete = false

    private var username: String { adminStr(user, "username") }
    private var isBanned: Bool { adminBool(user, "banned") }
    private var isAdmin: Bool { adminBool(user, "is_admin") }
    private var verified: Bool { adminBool(user, "verified") }

    var body: some View {
        NavigationStack {
            Form {
                Section("账号信息") {
                    row("用户名", "@" + username)
                    row("VIP", adminStr(user, "vip_level").isEmpty ? "无" : adminStr(user, "vip_level"))
                    row("到期", String(adminStr(user, "vip_expires_at").prefix(16)))
                    row("状态", isBanned ? "已封禁" : "正常")
                }
                Section("设置 VIP") {
                    Picker("等级", selection: $vipLevel) {
                        ForEach(["vip", "svip", "bronze", "silver", "gold", "platinum"], id: \.self) { Text($0).tag($0) }
                    }
                    Picker("时长", selection: $vipMinutes) {
                        Text("30 分钟").tag(30); Text("1 小时").tag(60); Text("1 天").tag(1440)
                        Text("3 天").tag(4320); Text("7 天").tag(10080); Text("30 天").tag(43200)
                    }
                    .disabled(vipPerm)
                    Toggle("永久", isOn: $vipPerm)
                    Button("应用 VIP") { Task { await applyVip() } }
                }
                Section("权限") {
                    Button(isAdmin ? "取消管理员" : "设为管理员") { Task { await toggleAdmin() } }
                    Button(verified ? "取消认证" : "设为认证用户") { Task { await toggleVerified() } }
                }
                Section("封禁") {
                    TextField("封禁理由", text: $banReason)
                    if isBanned {
                        Button("解封") { Task { await run(AdminAPI.exec(action: "unban", target: username, detail: "")) } }
                    } else {
                        Button("封禁该用户", role: .destructive) {
                            Task { await run(AdminAPI.exec(action: "ban", target: username, detail: banReason.isEmpty ? "管理员封禁" : banReason)) }
                        }
                    }
                }
                Section("重置密码") {
                    SecureField("新密码", text: $newPwd)
                    Button("重置") { Task { await resetPwd() } }.disabled(newPwd.count < 4)
                }
                Section {
                    Button("删除该用户", role: .destructive) { confirmDelete = true }
                }
                if !note.isEmpty { Section { Text(note).font(.callout) } }
            }
            .navigationTitle("用户详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .confirmationDialog("确定删除用户 @\(username)？不可恢复", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("确认删除", role: .destructive) {
                    Task { await run(AdminAPI.exec(action: "delete_user", target: username, detail: "")) }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundColor(.secondary) }
    }

    private func run(_ r: (Bool, String)) async {
        note = r.0 ? "✅ 成功" : "❌ " + r.1
        if r.0 { onDone() }
    }

    private func applyVip() async {
        await run(AdminAPI.setVip(user: username, level: vipLevel,
                                  minutes: vipPerm ? nil : vipMinutes, permanent: vipPerm))
    }

    private func toggleAdmin() async {
        await run(AdminAPI.exec(action: "set_admin", target: username, detail: isAdmin ? "false" : "true"))
    }

    private func toggleVerified() async {
        do {
            try await SB.patch("rest/v1/user_accounts", query: [
                URLQueryItem(name: "username", value: "eq." + username)], body: ["verified": !verified])
            note = "✅ 已更新认证状态"
            onDone()
        } catch { note = "❌ 认证更新失败（权限）" }
    }

    private func resetPwd() async {
        await run(AdminAPI.resetPassword(target: username, newPassword: newPwd))
    }
}

// MARK: - 群发私信

struct AdminBroadcastView: View {
    @State private var recipients = ""
    @State private var content = ""
    @State private var note = ""
    @State private var sending = false

    var body: some View {
        Form {
            Section("收件人") {
                TextField("用户名（逗号分隔，留空=全体用户）", text: $recipients)
                TextField("私信内容", text: $content)
            }
            Button(sending ? "发送中…" : "发送") { Task { await send() } }
                .disabled(content.isEmpty || sending)
            if !note.isEmpty { Text(note).font(.callout) }
        }
        .navigationTitle("群发私信")
    }

    private func send() async {
        sending = true
        let sent = await AdminAPI.broadcastDM(recipientsText: recipients, content: content)
        note = sent > 0 ? "✅ 已发送 \(sent) 条" : "❌ 发送失败（无对象或无权限）"
        sending = false
    }
}

// MARK: - 私信总览 / 封禁记录

struct AdminMessagesView: View {
    @State private var msgs: [AdminAPI.RecentMsg] = []
    var body: some View {
        List {
            ForEach(msgs) { m in
                VStack(alignment: .leading, spacing: 3) {
                    Text("@\(m.from_user ?? "?") → @\(m.to_user ?? "?")").font(.subheadline).bold()
                    Text(MsgContent.parse(m.content ?? "").plainText).font(.callout).lineLimit(3)
                    Text(String((m.created_at ?? "").prefix(16))).font(.caption2).foregroundColor(.secondary)
                }
            }
            if msgs.isEmpty { Text("暂无数据").foregroundColor(.secondary) }
        }
        .navigationTitle("私信总览")
        .task { msgs = await AdminAPI.recentMessages() }
    }
}

struct AdminBansView: View {
    @State private var bans: [AdminAPI.BanRow] = []
    var body: some View {
        List {
            ForEach(bans) { b in
                VStack(alignment: .leading, spacing: 3) {
                    Text("@" + (b.username ?? "?")).font(.subheadline).bold()
                    if let r = b.reason, !r.isEmpty { Text(r).font(.callout) }
                    Text(String((b.created_at ?? "").prefix(16))).font(.caption2).foregroundColor(.secondary)
                }
            }
            if bans.isEmpty { Text("暂无封禁记录").foregroundColor(.secondary) }
        }
        .navigationTitle("封禁记录")
        .task { bans = await AdminAPI.recentBans() }
    }
}

// MARK: - 兑换码

struct AdminCodesView: View {
    @State private var codes: [AdminAPI.CodeRow] = []
    @State private var level = "vip"
    @State private var uses = 1
    @State private var minutes = 43200
    @State private var perm = false
    @State private var note = ""

    var body: some View {
        List {
            Section("生成兑换码") {
                Picker("等级", selection: $level) {
                    ForEach(["vip", "svip", "bronze", "silver", "gold", "platinum"], id: \.self) { Text($0).tag($0) }
                }
                Stepper("可用次数：\(uses)", value: $uses, in: 1...100)
                Picker("时长", selection: $minutes) {
                    Text("1 天").tag(1440); Text("7 天").tag(10080); Text("30 天").tag(43200)
                }
                .disabled(perm)
                Toggle("永久", isOn: $perm)
                Button("生成") { Task { await gen() } }
                if !note.isEmpty { Text(note).font(.callout) }
            }
            Section("已有兑换码 (\(codes.count))") {
                ForEach(codes) { c in
                    HStack {
                        Text(c.code ?? "?").font(.system(.subheadline, design: .monospaced))
                        Spacer()
                        Text((c.level ?? "") + " · 用 \(c.used_count?.value ?? 0)/\(c.uses?.value ?? 0)")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("兑换码")
        .task { codes = await AdminAPI.listCodes() }
    }

    private func gen() async {
        if let code = await AdminAPI.generateCode(level: level, uses: uses, minutes: minutes, permanent: perm) {
            note = "✅ 新码：" + code
        } else {
            note = "已生成（列表已刷新）"
        }
        codes = await AdminAPI.listCodes()
    }
}

// MARK: - 系统配置

struct AdminConfigView: View {
    @State private var rows: [[String: Any]] = []
    @State private var editKey = ""
    @State private var editValue = ""
    @State private var showEdit = false
    @State private var note = ""

    var body: some View {
        List {
            if !note.isEmpty { Text(note).font(.callout) }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                Button {
                    editKey = adminStr(r, "key")
                    editValue = adminStr(r, "value")
                    showEdit = true
                } label: {
                    HStack {
                        Text(adminStr(r, "key")).foregroundColor(.primary)
                        Spacer()
                        Text(adminStr(r, "value")).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
            if rows.isEmpty { Text("暂无配置项").foregroundColor(.secondary) }
        }
        .navigationTitle("系统配置")
        .task { await load() }
        .alert("修改配置", isPresented: $showEdit) {
            TextField("值", text: $editValue)
            Button("保存") { Task { await save() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text(editKey)
        }
    }

    private func load() async {
        rows = await AdminAPI.restRows("rest/v1/system_config", query: [
            URLQueryItem(name: "select", value: "key,value"),
            URLQueryItem(name: "order", value: "key.asc"),
            URLQueryItem(name: "limit", value: "200"),
        ])
    }

    private func save() async {
        let ok = await AdminAPI.configSet(key: editKey, value: editValue)
        note = ok ? "✅ 已保存 \(editKey)" : "❌ 保存失败"
        if ok { await load() }
    }
}

// MARK: - 爬虫控制台 (含作者抓)

struct AuthorScrapeForm: View {
    var presetAuthor: String = ""
    @EnvironmentObject var session: Session
    @State private var authors = ""
    @State private var maxPages = 5
    @State private var note = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("🎯 按作者抓取").font(.headline)
            TextField("作者名（多个用逗号或换行分隔，最多 10 个）", text: $authors)
                .autocorrectionDisabled()
            Stepper("每位作者翻页：\(maxPages) 页", value: $maxPages, in: 1...20)
            Button(busy ? "触发中…" : "开始作者抓") { Task { await run() } }
                .disabled(busy || authors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if !note.isEmpty { Text(note).font(.caption).foregroundColor(.secondary) }
            Text("云端按作者去源站逐页抓卡片入库并解析直链，约几分钟见效。")
                .font(.caption2).foregroundColor(.secondary)
        }
        .onAppear { if authors.isEmpty { authors = presetAuthor } }
    }

    private func run() async {
        let token = session.ghToken
        guard !token.isEmpty else { note = "❌ 还没有 GitHub 令牌"; return }
        busy = true
        let list = authors.split(whereSeparator: { ",，、\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let ok = await GitHub.dispatchWorkflow("author-scrape.yml", inputs: [
            "authors": Array(list.prefix(10)).joined(separator: ","),
            "max_pages": String(maxPages),
            "resolve": "300",
        ], token: token)
        note = ok ? "✅ 已触发，云端开始抓 \(list.count) 位作者" : "❌ 触发失败（令牌权限/工作流）"
        busy = false
    }
}

struct AdminScrapeView: View {
    @EnvironmentObject var session: Session
    @State private var note = ""
    @State private var statusRows: [[String: Any]] = []

    private let modes: [(String, String)] = [
        ("full", "完整抓取"), ("resolve", "只解析直链"), ("deep", "深挖（作者/ID扫段）"),
        ("test", "连通性自检"), ("hsex", "只抓 Hsex"), ("iwara", "只抓 Iwara"),
    ]

    var body: some View {
        List {
            Section("抓取模式") {
                ForEach(modes, id: \.0) { m in
                    Button(m.1) { Task { await dispatch(mode: m.0) } }
                }
                if !note.isEmpty { Text(note).font(.caption) }
            }
            Section { AuthorScrapeForm() }
            Section("补数任务") {
                Button("补文案（标题/作者）") { Task { await dispatchWorkflow("text-backfill.yml", ["limit": "120"]) } }
                Button("补 MP4 直链") { Task { await dispatchWorkflow("mp4-backfill.yml", ["batch": "200"]) } }
            }
            Section("最近抓取状态") {
                if statusRows.isEmpty { Text("暂无").foregroundColor(.secondary) }
                ForEach(Array(statusRows.enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(r.keys.sorted()), id: \.self) { k in
                            Text("\(k): \(adminStr(r, k))").font(.caption2)
                        }
                    }
                }
            }
        }
        .navigationTitle("爬虫控制台")
        .task { await loadStatus() }
    }

    private func loadStatus() async {
        statusRows = await AdminAPI.restRows("rest/v1/scrape_status", query: [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "2"),
        ])
    }

    private func dispatch(mode: String) async {
        let token = session.ghToken
        guard !token.isEmpty else { note = "❌ 还没有 GitHub 令牌"; return }
        let ok = await GitHub.dispatch(mode: mode, token: token)
        note = ok ? "✅ 已触发 \(mode)" : "❌ 触发失败"
    }

    private func dispatchWorkflow(_ file: String, _ inputs: [String: String]) async {
        let token = session.ghToken
        guard !token.isEmpty else { note = "❌ 还没有 GitHub 令牌"; return }
        let ok = await GitHub.dispatchWorkflow(file, inputs: inputs, token: token)
        note = ok ? "✅ 已触发 \(file)" : "❌ 触发失败"
    }
}

// MARK: - 数据维护

struct AdminDataView: View {
    @State private var note = ""
    @State private var confirmPurge = false
    @State private var exportText = ""

    var body: some View {
        List {
            Section("清理") {
                Button("彻底删除「已下架」视频", role: .destructive) { confirmPurge = true }
                Text("把 removed 的视频从数据库真删（走站长删除接口），不可恢复。")
                    .font(.caption2).foregroundColor(.secondary)
            }
            Section("导出") {
                Button("生成视频清单（JSON）") { Task { await exportList() } }
                if !exportText.isEmpty {
                    Button {
                        UIPasteboard.general.string = exportText
                        note = "✅ 清单已复制到剪贴板"
                    } label: { Label("复制清单到剪贴板", systemImage: "doc.on.doc") }
                }
            }
            if !note.isEmpty { Section { Text(note).font(.callout) } }
        }
        .navigationTitle("数据维护")
        .confirmationDialog("确定真删全部已下架视频？", isPresented: $confirmPurge, titleVisibility: .visible) {
            Button("确认真删", role: .destructive) { Task { await purge() } }
            Button("取消", role: .cancel) {}
        }
    }

    private func purge() async {
        let rows = await AdminAPI.restRows("rest/v1/videos", query: [
            URLQueryItem(name: "removed", value: "eq.true"),
            URLQueryItem(name: "select", value: "video_id"),
            URLQueryItem(name: "limit", value: "1000"),
        ])
        let ids = rows.map { adminStr($0, "video_id") }.filter { !$0.isEmpty }
        if ids.isEmpty { note = "没有已下架的视频"; return }
        var deleted = 0
        for chunk in stride(from: 0, to: ids.count, by: 100) {
            deleted += await AdminAPI.deleteVideos(ids: Array(ids[chunk..<min(chunk + 100, ids.count)]))
        }
        note = "✅ 已真删 \(deleted) / \(ids.count) 条"
    }

    private func exportList() async {
        let rows = await AdminAPI.restRows("rest/v1/videos", query: [
            URLQueryItem(name: "select", value: "video_id,title,author,views,source_section"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "1000"),
        ])
        let data = (try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted])) ?? Data()
        exportText = String(data: data, encoding: .utf8) ?? ""
        note = "已生成 \(rows.count) 条清单，点下面分享保存"
    }
}

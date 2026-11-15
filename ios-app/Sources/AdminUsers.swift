import SwiftUI
import UIKit

// 由 AdminOps.swift 拆分 (v5.2: 每个功能一个文件, 方便定位问题)

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
                        badge("ID " + adminStr(r, "id"), .gray)
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
            URLQueryItem(name: "select", value: "id,username,vip_level,vip_expires_at,is_admin,verified,banned,created_at"),
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
    @State private var confirmBan = false

    private var username: String { adminStr(user, "username") }
    private var isBanned: Bool { adminBool(user, "banned") }
    private var isAdmin: Bool { adminBool(user, "is_admin") }
    private var verified: Bool { adminBool(user, "verified") }

    var body: some View {
        NavigationView {
            Form {
                Section("账号信息") {
                    row("用户名", "@" + username)
                    row("用户ID", adminStr(user, "id"))
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
                        // 先弹窗确认, 点"确认封禁"的那一刻立即生效 (不是直接执行)
                        Button("封禁该用户", role: .destructive) { confirmBan = true }
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
            .confirmationDialog("封禁 @\(username)？", isPresented: $confirmBan, titleVisibility: .visible) {
                Button("确认封禁 (立即生效)", role: .destructive) {
                    Task { await run(AdminAPI.exec(action: "ban", target: username, detail: banReason.isEmpty ? "管理员封禁" : banReason)) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("点击确认的这一刻对方立即被封禁：不能评论、不能发弹幕、不能发私信/留言板消息、不能发布作品，什么言论都发不了；对方只能通过「联系站主」申诉，且每小时限发一条。")
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
        // 必须走 admin_exec 的 verify/unverify (与网站一致):
        // user_accounts 表禁止直接改表 (RLS 无 UPDATE 权限), 之前的直连 PATCH 必然失败
        await run(AdminAPI.exec(action: verified ? "unverify" : "verify", target: username, detail: ""))
    }

    private func resetPwd() async {
        await run(AdminAPI.resetPassword(target: username, newPassword: newPwd))
    }
}

// MARK: - 群发私信

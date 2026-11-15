import SwiftUI
import UIKit

// 由 AdminOps.swift 拆分 (v5.2: 每个功能一个文件, 方便定位问题)

struct TokenConfigView: View {
    @EnvironmentObject var session: Session
    @State private var gh = ""
    @State private var sb = ""
    @State private var note = ""
    @State private var hasKey = false

    var body: some View {
        List {
            Section {
                Text("爬作者、触发爬虫要用 GitHub 令牌；Supabase 令牌用于后台维护。令牌加密后跟账号存云端，换设备登录同一账号会自动取回。")
                    .font(.callout).foregroundColor(.secondary)
            }
            Section("GitHub 令牌") {
                HStack {
                    Text("当前状态")
                    Spacer()
                    Text(session.ghToken.isEmpty ? "未配置" : "已配置 ✓")
                        .foregroundColor(session.ghToken.isEmpty ? .red : .green)
                }
                SecureField("粘贴新的 GitHub 令牌", text: $gh)
                    .autocapitalization(.none)
                    .autocorrectionDisabled(true)
                Button("从剪贴板粘贴") {
                    if let s = UIPasteboard.general.string { gh = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
            }
            Section("Supabase 令牌") {
                HStack {
                    Text("当前状态")
                    Spacer()
                    Text(session.sbToken.isEmpty ? "未配置" : "已配置 ✓")
                        .foregroundColor(session.sbToken.isEmpty ? .red : .green)
                }
                SecureField("粘贴新的 Supabase 令牌", text: $sb)
                    .autocapitalization(.none)
                    .autocorrectionDisabled(true)
                Button("从剪贴板粘贴") {
                    if let s = UIPasteboard.general.string { sb = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
            }
            Section {
                Button("保存") { Task { await save() } }
                    .disabled(gh.isEmpty && sb.isEmpty)
                Button("从云端重新拉取") {
                    Task {
                        await TokenVault.pullTokens(session: session)
                        note = "已从云端拉取（状态见上方）"
                    }
                }
            }
            if !hasKey {
                Section {
                    Text("⚠️ 当前没有解密密钥（多半是自动登录进来的）：保存后本机立刻能用，但暂时同步不到云端。退出后用密码重新登录一次，密钥会自动重建，之后就跟账号走了。")
                        .font(.callout).foregroundColor(.orange)
                }
            }
            if !note.isEmpty { Section { Text(note).font(.callout) } }
        }
        .navigationTitle("令牌配置")
        .onAppear { hasKey = (TokenVault.loadKey(for: session.username ?? "") != nil || TokenVault.loadLegacyKey() != nil) }
    }

    private func save() async {
        if !gh.isEmpty { session.ghToken = gh.trimmingCharacters(in: .whitespacesAndNewlines) }
        if !sb.isEmpty { session.sbToken = sb.trimmingCharacters(in: .whitespacesAndNewlines) }
        await TokenVault.pushTokens(session: session)
        gh = ""; sb = ""
        hasKey = (TokenVault.loadKey(for: session.username ?? "") != nil || TokenVault.loadLegacyKey() != nil)
        // pushTokens 没有密钥时是静默不同步的, 保存结果必须说实话:
        // 有密钥 = 已加密存云端、跟账号走; 没密钥 = 只存了本机, 切号/重装就没了
        note = hasKey
            ? "已保存 ✓ 已加密同步到云端，现在可以去爬作者了"
            : "已存到本机 ✓ 但还没同步云端：当前没有解密密钥（自动登录进来的），退出后用密码登录一次，再回来点一次保存就跟账号走了"
    }
}

// MARK: - 系统配置

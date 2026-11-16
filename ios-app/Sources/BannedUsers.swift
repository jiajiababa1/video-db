import SwiftUI

/// 封禁名单 (站主专属): 当前被封的全部账号 + 一键解封 (与「封禁记录」的历史流水不同)
struct BannedUsersView: View {
    @State private var rows: [[String: Any]] = []
    @State private var note = ""

    var body: some View {
        List {
            if !note.isEmpty {
                Text(note).font(.caption).foregroundColor(.secondary)
            }
            if rows.isEmpty {
                Text("当前没有被封禁的账号").foregroundColor(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("@" + adminStr(r, "username"))
                            .font(.system(size: 14, weight: .semibold))
                        Text("注册 \(String(adminStr(r, "created_at").prefix(10))) · 最近登录 \(String(adminStr(r, "last_login").prefix(16)))")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("解封") {
                        Task { await unban(adminStr(r, "username")) }
                    }
                    .font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Theme.goldGradient).foregroundColor(.black)
                    .cornerRadius(99)
                }
            }
        }
        .navigationTitle("封禁名单")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        rows = await AdminAPI.restRows("rest/v1/user_accounts", query: [
            URLQueryItem(name: "select", value: "username,created_at,last_login"),
            URLQueryItem(name: "banned", value: "eq.true"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "100"),
        ])
    }

    private func unban(_ user: String) async {
        guard !user.isEmpty else { return }
        let (ok, msg) = await AdminAPI.exec(action: "unban", target: user, detail: "")
        note = ok ? "已解封 @\(user)" : ("解封失败：" + msg)
        if ok { await load() }
    }
}

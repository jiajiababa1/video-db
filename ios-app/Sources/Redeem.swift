import SwiftUI
import UIKit

// 由 Profile.swift 拆分 (v5.2: 每个功能一个文件, 方便定位问题)

/// 兑换 VIP 页: 输入兑换码走 redeem_code (服务端验码), 成功后刷新会话等级。
/// (入口曾在旧「我的」页里, v4.0 改版换主页时丢了, 这里正式补回: 设置 + 抽屉各一个入口)
struct RedeemView: View {
    @EnvironmentObject var session: Session
    @State private var code = ""
    @State private var note = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                Text("输入站主发放的兑换码，兑换 VIP 时长，兑换后立即生效。")
                    .font(.callout).foregroundColor(.secondary)
            }
            Section("兑换码") {
                TextField("输入兑换码", text: $code)
                    .autocapitalization(.allCharacters)
                    .autocorrectionDisabled(true)
                Button("粘贴") {
                    if let s = UIPasteboard.general.string {
                        code = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
            Section {
                Button(busy ? "兑换中…" : "立即兑换") { Task { await redeem() } }
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
            if !note.isEmpty { Section { Text(note).font(.callout) } }
        }
        .navigationTitle("兑换 VIP")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func redeem() async {
        guard let me = session.username else { note = "请先登录"; return }
        busy = true
        let r = await AccountAPI.redeem(user: me, code: code)
        note = r.msg
        if r.ok {
            code = ""
            await session.validateSession()
        }
        busy = false
    }
}

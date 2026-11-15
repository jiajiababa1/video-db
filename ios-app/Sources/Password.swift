import SwiftUI

/// 修改密码 (v4.0 改版时随旧 MeView 一起丢失, v5.2 补回并独立成文件)。
/// 改密成功后必须衔接令牌密钥: 云端令牌密文是用旧密码派生的密钥加密的,
/// 这里用新密码重新派生密钥, 把本机明文令牌重新加密覆盖上云,
/// 否则换设备/重装后令牌再也拉不回来; 钥匙串里存的自动重登密码也同步更新。
struct ChangePasswordView: View {
    @EnvironmentObject var session: Session
    @State private var oldPass = ""
    @State private var newPass = ""
    @State private var newPass2 = ""
    @State private var busy = false
    @State private var note: String? = nil
    @State private var done = false

    var body: some View {
        Form {
            Section(header: Text("修改密码")) {
                SecureField("旧密码", text: $oldPass)
                SecureField("新密码 (至少 4 位)", text: $newPass)
                SecureField("再输一次新密码", text: $newPass2)
            }
            if let note = note {
                Text(note)
                    .font(.footnote)
                    .foregroundColor(done ? .green : .red)
            }
            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        Spacer()
                        Text(busy ? "提交中…" : "确认修改")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(busy || oldPass.isEmpty || newPass.count < 4 || newPass != newPass2)
                if done {
                    Button("用新密码重新登录") {
                        session.signOutLocal()
                    }
                    .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("修改密码")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func submit() async {
        guard let user = session.username else { return }
        busy = true
        let r = await AccountAPI.changePassword(user: user, old: oldPass, new: newPass)
        if r.ok {
            // 密钥衔接: 新密码派生新密钥 → 本机令牌重新加密上云; 自动重登密码同步更新为新密码
            if let key = TokenVault.deriveKey(password: newPass) {
                TokenVault.saveKey(key, for: user)
                await TokenVault.pushTokens(session: session, forceKey: key)
            }
            SessionKeychain.set(newPass, account: "pwd_" + user)
            done = true
            note = "密码已修改。建议退出后用新密码重新登录一次。"
            oldPass = ""; newPass = ""; newPass2 = ""
        } else {
            note = r.msg
        }
        busy = false
    }
}

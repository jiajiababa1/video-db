import SwiftUI

/// 切换账号: 已保存的账号点一下直接换 (令牌在钥匙串), 不用再输密码
struct AccountSwitcherView: View {
    @EnvironmentObject var session: Session
    @Environment(\.presentationMode) private var presentationMode
    @State private var switching = false

    var body: some View {
        List {
            Section(header: Text("已保存的账号")) {
                if session.savedAccounts.isEmpty {
                    Text("暂无保存的账号, 登录后会自动出现在这里")
                        .foregroundColor(Theme.sub)
                }
                ForEach(session.savedAccounts) { acc in
                    Button {
                        guard acc.username != session.username else { return }
                        switching = true
                        Task {
                            await session.switchAccount(to: acc.username)
                            switching = false
                            presentationMode.wrappedValue.dismiss()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(Theme.goldGradient)
                                Text(String(acc.username.prefix(1)).uppercased())
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            .frame(width: 42, height: 42)
                            Text(acc.username)
                                .font(.system(size: 15.5, weight: .semibold))
                                .foregroundColor(Theme.text)
                            Spacer()
                            if acc.username == session.username {
                                Text("当前")
                                    .font(.system(size: 11, weight: .bold))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Theme.goldGradient)
                                    .foregroundColor(.white)
                                    .cornerRadius(99)
                            } else {
                                Text("切换")
                                    .font(.system(size: 12.5))
                                    .foregroundColor(Theme.gold2)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(switching)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            session.removeAccount(acc.username)
                        } label: {
                            Label("移除", systemImage: "trash")
                        }
                    }
                }
            }
            Section {
                NavigationLink { AuthView() } label: {
                    Label("添加账号 (登录新账号)", systemImage: "plus.circle")
                }
                if session.isLoggedIn {
                    Button {
                        session.signOutLocal()
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        Label("退出当前账号 (保留在列表, 可一键切回)", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            Section {
                Text("说明: 切换后与密码绑定的云端令牌 (GitHub / Supabase 管理) 需要用密码登录一次才恢复, 其余功能直接可用。左滑可移除账号, 移除当前账号等于完整退出登录。")
                    .font(.caption)
                    .foregroundColor(Theme.sub)
            }
        }
        .navigationTitle("切换账号")
        .navigationBarTitleDisplayMode(.inline)
    }
}

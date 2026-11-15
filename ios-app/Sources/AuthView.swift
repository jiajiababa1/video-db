import SwiftUI

// 由 MeView.swift 拆分 (v5.2: 每个功能一个文件, 方便定位问题)

/// 登录 / 注册页 (v1.6 起 App 内可注册: 验证码与网站同源 xxapi 数学题)
struct AuthView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0   // 0 登录 1 注册
    @State private var user = ""
    @State private var pass = ""
    @State private var pass2 = ""
    @State private var captchaId = ""
    @State private var captchaImg: UIImage? = nil
    @State private var captchaAnswer = ""
    @State private var error: String? = nil
    @State private var busy = false

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Text(mode == 0 ? "登录账号" : "注册新账号")
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundStyle(Theme.goldGradient)
                    .padding(.top, 30)
                Picker("模式", selection: $mode) {
                    Text("登录").tag(0)
                    Text("注册").tag(1)
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) { m in
                    error = nil
                    if m == 1 { Task { await loadCaptcha() } }
                }
                TextField("用户名", text: $user)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 13).padding(.vertical, 12)
                    .background(Theme.surface2).cornerRadius(12)
                SecureField("密码", text: $pass)
                    .padding(.horizontal, 13).padding(.vertical, 12)
                    .background(Theme.surface2).cornerRadius(12)
                if mode == 1 {
                    SecureField("确认密码", text: $pass2)
                        .padding(.horizontal, 13).padding(.vertical, 12)
                        .background(Theme.surface2).cornerRadius(12)
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10).fill(Color.white)
                            if let img = captchaImg {
                                Image(uiImage: img).resizable().scaledToFit().padding(4)
                            } else {
                                ProgressView()
                            }
                        }
                        .frame(width: 150, height: 56)
                        Button("↻ 换一张") { Task { await loadCaptcha() } }
                            .font(.footnote).foregroundColor(Theme.gold2)
                        Spacer()
                    }
                    TextField("输入图中运算结果（可为负数）", text: $captchaAnswer)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 13).padding(.vertical, 12)
                        .background(Theme.surface2).cornerRadius(12)
                }
                if let e = error {
                    Text(e).foregroundColor(.red).font(.footnote)
                }
                Button {
                    Task { await submit() }
                } label: {
                    Text(busy ? "处理中…" : (mode == 0 ? "登录" : "注册并登录"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Theme.goldGradient)
                        .foregroundColor(.black)
                        .cornerRadius(12)
                }
                .disabled(busy || user.isEmpty || pass.isEmpty)
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

    private func loadCaptcha() async {
        captchaImg = nil
        captchaAnswer = ""
        struct Cap: Decodable {
            struct D: Decodable { var id: String?; var url: String? }
            var data: D?
        }
        let url = URL(string: "https://v2.xxapi.cn/api/captcha?type=math&t="
            + String(Int(Date().timeIntervalSince1970 * 1000)))!
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let cap = try? JSONDecoder().decode(Cap.self, from: data),
              let id = cap.data?.id, let dataURI = cap.data?.url,
              let b64 = dataURI.split(separator: ",").last,
              let imgData = Data(base64Encoded: String(b64)),
              let img = UIImage(data: imgData) else {
            error = "验证码加载失败, 点「换一张」重试"
            return
        }
        captchaId = id
        captchaImg = img
    }

    private func submit() async {
        if mode == 1 {
            guard pass == pass2 else { error = "两次密码不一致"; return }
            guard pass.count >= 4 else { error = "密码至少 4 位"; return }
            guard !captchaId.isEmpty else { error = "验证码未加载, 点「换一张」"; return }
            guard !captchaAnswer.trimmingCharacters(in: .whitespaces).isEmpty else {
                error = "请输入验证码运算结果"
                return
            }
        }
        busy = true
        if mode == 0 {
            error = await session.login(username: user, password: pass)
        } else {
            error = await session.register(username: user, password: pass,
                                           captchaId: captchaId,
                                           captchaKey: captchaAnswer.trimmingCharacters(in: .whitespaces))
            if error != nil { await loadCaptcha() }   // 失败刷新验证码 (与网站一致)
        }
        busy = false
        if error == nil { dismiss() }
    }
}

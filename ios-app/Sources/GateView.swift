import SwiftUI

/// 进站门禁 (与网站同: 4 位动态口令 verify_passcode)
struct GateView: View {
    @EnvironmentObject var session: Session
    @State private var code = ""
    @State private var error: String? = nil
    @State private var busy = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Text("2048 影院")
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(Theme.goldGradient)
            Text("输入 4 位口令进入")
                .foregroundColor(Theme.sub)
                .font(.subheadline)
            SecureField("4 位口令", text: $code)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .padding(.vertical, 14)
                .background(Theme.surface2)
                .cornerRadius(14)
                .padding(.horizontal, 60)
            if let e = error {
                Text(e).foregroundColor(.red).font(.footnote)
            }
            Button {
                Task { await submit() }
            } label: {
                Text(busy ? "验证中…" : "进入")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.goldGradient)
                    .foregroundColor(.black)
                    .cornerRadius(14)
            }
            .disabled(busy || code.count < 4)
            .padding(.horizontal, 60)
            Spacer()
            Spacer()
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    private func submit() async {
        busy = true
        error = await session.verifyPasscode(code)
        busy = false
        if error != nil { code = "" }
    }
}

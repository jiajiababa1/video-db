import SwiftUI
import UIKit

// 由 Profile.swift 拆分 (v5.2: 每个功能一个文件, 方便定位问题)

/// 封禁申诉页: 被封禁用户唯一能发出的消息, 每小时限一条 (服务端 send_appeal 验权+限流)
struct AppealView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var note = ""
    @State private var sending = false

    var body: some View {
        Form {
            Section {
                Text("你的账号已被封禁，无法发表任何言论（评论、弹幕、私信、留言板、作品都不能发）。如需解封，可以在这里向站主申诉，每小时只能发送一条。")
                    .font(.callout)
            }
            Section("申诉内容") {
                TextField("说明情况…", text: $draft)
            }
            if session.appealWaitSeconds > 0 {
                Section {
                    Text("刚申诉过，请约 \(Int(ceil(Double(session.appealWaitSeconds) / 60.0))) 分钟后再发下一条")
                        .foregroundColor(.secondary)
                }
            }
            Section {
                Button(sending ? "发送中…" : "发送申诉") { Task { await send() } }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || sending || session.appealWaitSeconds > 0)
            }
            if !note.isEmpty { Section { Text(note).font(.callout) } }
        }
        .navigationTitle("联系站主申诉")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        .task { await session.fetchBanStatus() }
    }

    private func send() async {
        sending = true
        struct R: Decodable { var ok: Bool?; var message: String? }
        let rows: [R]? = try? await SB.rpc("send_appeal", params: [
            "p_token": session.loginToken,
            "p_content": draft.trimmingCharacters(in: .whitespacesAndNewlines)])
        if rows?.first?.ok == true {
            note = "已发送，站主会看到你的申诉。下一次可发送时间：1 小时后。"
            draft = ""
        } else {
            note = rows?.first?.message ?? "发送失败，请稍后再试"
        }
        await session.fetchBanStatus()
        sending = false
    }
}

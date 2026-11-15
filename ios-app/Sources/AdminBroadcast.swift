import SwiftUI
import UIKit

// 由 AdminOps.swift 拆分 (v5.2: 每个功能一个文件, 方便定位问题)

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
        let (sent, err) = await AdminAPI.broadcastDM(recipientsText: recipients, content: content)
        note = sent > 0 ? "✅ 已发送 \(sent) 条" : "❌ " + err
        sending = false
    }
}

// MARK: - 私信总览 / 封禁记录

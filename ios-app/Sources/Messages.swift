import SwiftUI

// MARK: - 私信 (与网站同: get_conversation_t / send_message_t / unread_count_t)
struct DMMessage: Decodable {
    var from_user: String?
    var content: String?
    var created_at: String?

    var timeText: String {
        guard let c = created_at else { return "" }
        return String(c.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }

    /// 内容多态: 纯文本, 或 JSON {t:'sticker'|'voice'|'loc', ...}
    var displayText: String {
        let c = content ?? ""
        if c.hasPrefix("{"), let data = c.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let t = obj["t"] as? String {
            switch t {
            case "sticker": return "[表情]"
            case "voice": return "🎤 语音消息"
            case "loc": return "📍 位置分享"
            default: return c
            }
        }
        return c
    }
}

enum DMAPI {
    static func conversation(token: String, with user: String) async -> [DMMessage] {
        let rows: [DMMessage] = (try? await SB.rpc("get_conversation_t",
            params: ["p_token": token, "p_with": user, "p_limit": 50])) ?? []
        return rows.reversed()
    }

    static func send(token: String, to: String, content: String) async -> Bool {
        struct R: Decodable { var ok: Bool? }
        let rows: [R] = (try? await SB.rpc("send_message_t",
            params: ["p_token": token, "p_to": to, "p_content": content])) ?? []
        return rows.first?.ok ?? true
    }

    static func unread(token: String) async -> Int {
        struct R: Decodable { var cnt: FlexInt? }
        let rows: [R] = (try? await SB.rpc("unread_count_t",
            params: ["p_token": token])) ?? []
        return rows.first?.cnt?.value ?? 0
    }
}

/// 私信会话窗 (文字/表情/语音/位置/图片/视频/文件, 与网站消息格式互通)
struct ChatView: View {
    let peer: String
    @EnvironmentObject var session: Session
    @State private var msgs: [DMMessage] = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(msgs.enumerated()), id: \.offset) { _, m in
                            bubble(m)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(14)
                }
                .onChange(of: msgs.count) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            Divider().background(Theme.line)
            ChatSendBar { content in
                Task { await send(content) }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("@" + peer)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await reload()
            // 打开会话期间每 10 秒拉一次新消息
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { break }
                await reload()
            }
        }
    }

    private func bubble(_ m: DMMessage) -> some View {
        let mine = m.from_user == session.username
        return HStack {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                MessageBubble(content: MsgContent.parse(m.content ?? ""), isMe: mine)
                Text(m.timeText)
                    .font(.caption2).foregroundColor(Theme.sub)
            }
            if !mine { Spacer(minLength: 48) }
        }
    }

    private func reload() async {
        guard session.isLoggedIn else { return }
        msgs = await DMAPI.conversation(token: session.loginToken, with: peer)
    }

    private func send(_ content: MsgContent) async {
        if await DMAPI.send(token: session.loginToken, to: peer, content: content.serialized) {
            await reload()
        }
    }
}

// MARK: - 账号设置 (改密码 / 兑换码)
enum AccountAPI {
    static func changePassword(user: String, old: String, new: String) async -> (ok: Bool, msg: String) {
        struct R: Decodable { var ok: Bool?; var message: String? }
        let rows: [R] = (try? await SB.rpc("change_password",
            params: ["p_username": user, "p_old_password": old, "p_new_password": new])) ?? []
        let r = rows.first
        return (r?.ok ?? false, r?.message ?? "修改失败")
    }

    static func redeem(user: String, code: String) async -> (ok: Bool, msg: String) {
        struct R: Decodable { var ok: Bool?; var message: String? }
        let rows: [R] = (try? await SB.rpc("redeem_code",
            params: ["p_username": user, "p_code": code.trimmingCharacters(in: .whitespaces).uppercased()])) ?? []
        let r = rows.first
        return (r?.ok ?? false, r?.message ?? "兑换失败")
    }
}

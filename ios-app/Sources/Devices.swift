import SwiftUI
import UIKit

// 由 Features21.swift 拆分 (v5.2: 每个功能一个文件, 方便定位问题)

struct DevicesView: View {
    struct Row: Decodable, Identifiable {
        var device_id: String?
        var expires_at: String?
        var is_current: Bool?
        var id: String { device_id ?? UUID().uuidString }
    }

    @State private var rows: [Row] = []
    @State private var loaded = false
    @State private var note = ""

    var body: some View {
        List {
            Section {
                if loaded && rows.isEmpty {
                    Text("没有登录设备记录").foregroundColor(.secondary)
                }
                ForEach(rows) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(deviceName(r.device_id))
                                .font(.system(size: 13.5, weight: .semibold))
                                .lineLimit(1)
                            Text("有效期至 " + String((r.expires_at ?? "").prefix(10)))
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        if r.is_current == true {
                            Text("本机")
                                .font(.caption2.bold()).foregroundColor(.white)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Theme.gold).cornerRadius(99)
                        } else {
                            Button("踢下线") { Task { await kick(r) } }
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.red)
                        }
                    }
                }
            } header: {
                Text("登录设备")
            } footer: {
                Text("踢下线后, 那台设备下次打开 App 就要重新登录。")
            }
            if !note.isEmpty {
                Section { Text(note).font(.footnote) }
            }
        }
        .navigationTitle("我的设备")
        .task {
            if !loaded {
                loaded = true
                await load()
            }
        }
    }

    private func deviceName(_ id: String?) -> String {
        guard let id = id, !id.isEmpty else { return "未知设备" }
        return "设备 " + String(id.prefix(12))
    }

    private func load() async {
        let rs: [Row]? = try? await SB.rpc("my_sessions", params: [
            "p_token": Session.shared.loginToken])
        rows = rs ?? []
    }

    private func kick(_ r: Row) async {
        guard let did = r.device_id else { return }
        struct KR: Decodable { var ok: Bool?; var message: String? }
        let rs: [KR]? = try? await SB.rpc("kick_session", params: [
            "p_token": Session.shared.loginToken, "p_device_id": did])
        note = rs?.first?.ok == true ? "已踢下线" : "操作失败, 请稍后再试"
        await load()
    }
}

// MARK: - 站主审计日志

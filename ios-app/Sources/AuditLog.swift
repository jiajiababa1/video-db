import SwiftUI
import UIKit

// 由 Features21.swift 拆分 (v5.2: 每个功能一个文件, 方便定位问题)

struct AuditLogView: View {
    struct Row: Decodable, Identifiable {
        var id: Int?
        var admin_user: String?
        var action: String?
        var target: String?
        var detail: String?
        var created_at: String?
    }

    @State private var rows: [Row] = []
    @State private var loaded = false
    @State private var failed = false

    var body: some View {
        List {
            if failed {
                Text("日志暂时读不到 (接口未返回数据)")
                    .foregroundColor(.secondary)
            } else if loaded && rows.isEmpty {
                Text("还没有管理操作记录")
                    .foregroundColor(.secondary)
            }
            ForEach(rows) { r in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(r.admin_user ?? "?")
                            .font(.system(size: 13, weight: .bold))
                        Text(r.action ?? "")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.gold2)
                        Spacer()
                        Text(String((r.created_at ?? "").prefix(16)).replacingOccurrences(of: "T", with: " "))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    if let t = r.target, !t.isEmpty {
                        Text("对象: " + t)
                            .font(.caption).foregroundColor(.secondary)
                    }
                    if let d = r.detail, !d.isEmpty {
                        Text(d)
                            .font(.caption).foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("审计日志")
        .task {
            if !loaded {
                loaded = true
                await load()
            }
        }
    }

    private func load() async {
        do {
            let rs: [Row] = try await SB.rpc("get_audit_log", params: [
                "p_token": Session.shared.loginToken, "p_limit": 100])
            rows = rs
        } catch {
            failed = true
        }
    }
}

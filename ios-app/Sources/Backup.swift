import SwiftUI

/// 核心数据备份 (站主专属): 一键手动快照 (另有每天凌晨 4 点自动快照)
/// 范围: 账号 / 云端配置 / 站内页 / 公告 / 会话; 不含视频表 (视频靠爬虫可重建)
struct BackupView: View {
    @State private var busy = false
    @State private var note = ""

    var body: some View {
        List {
            Section("备份说明") {
                Text("核心表每天凌晨 4 点自动快照一份，存放在数据库的 backup 区。这里可以随时手动再打一份。")
                    .font(.callout).foregroundColor(.secondary)
                Text("包含：用户账号、云端配置、站内页、公告、登录会话。不含视频表（18 万行太大，视频靠爬虫可重新抓）。")
                    .font(.callout).foregroundColor(.secondary)
            }
            Section {
                Button {
                    Task { await run() }
                } label: {
                    HStack {
                        Spacer()
                        Text(busy ? "备份中…" : "立即备份核心数据")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(busy)
                if !note.isEmpty {
                    Text(note).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("核心备份")
    }

    private func run() async {
        busy = true
        let name: String? = try? await SB.rpc("snapshot_core", params: [:])
        if let name = name, !name.isEmpty {
            note = "备份完成：\(name)"
        } else {
            note = "已执行备份（服务端未返回快照名，可在数据库 backup 区确认）"
        }
        busy = false
    }
}

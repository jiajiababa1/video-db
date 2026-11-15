import SwiftUI
import UIKit

// 由 AdminOps.swift 拆分 (v5.2: 每个功能一个文件, 方便定位问题)

struct AdminConfigView: View {
    @State private var rows: [[String: Any]] = []
    @State private var editKey = ""
    @State private var editValue = ""
    @State private var showEdit = false
    @State private var note = ""

    var body: some View {
        List {
            if !note.isEmpty { Text(note).font(.callout) }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                Button {
                    editKey = adminStr(r, "key")
                    editValue = adminStr(r, "value")
                    showEdit = true
                } label: {
                    HStack {
                        Text(adminStr(r, "key")).foregroundColor(.primary)
                        Spacer()
                        Text(adminStr(r, "value")).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
            if rows.isEmpty { Text("暂无配置项").foregroundColor(.secondary) }
        }
        .navigationTitle("系统配置")
        .task { await load() }
        .alert("修改配置", isPresented: $showEdit) {
            TextField("值", text: $editValue)
            Button("保存") { Task { await save() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text(editKey)
        }
    }

    private func load() async {
        rows = await AdminAPI.restRows("rest/v1/system_config", query: [
            URLQueryItem(name: "select", value: "key,value"),
            URLQueryItem(name: "order", value: "key.asc"),
            URLQueryItem(name: "limit", value: "200"),
        ])
    }

    private func save() async {
        let ok = await AdminAPI.configSet(key: editKey, value: editValue)
        note = ok ? "✅ 已保存 \(editKey)" : "❌ 保存失败"
        if ok { await load() }
    }
}

// MARK: - 爬虫控制台 (含作者抓)

struct AdminDataView: View {
    @State private var note = ""
    @State private var confirmPurge = false
    @State private var exportText = ""

    var body: some View {
        List {
            Section("清理") {
                Button("彻底删除「已下架」视频", role: .destructive) { confirmPurge = true }
                Text("把 removed 的视频从数据库真删（走站长删除接口），不可恢复。")
                    .font(.caption2).foregroundColor(.secondary)
            }
            Section("导出") {
                Button("生成视频清单（JSON）") { Task { await exportList() } }
                if !exportText.isEmpty {
                    Button {
                        UIPasteboard.general.string = exportText
                        note = "✅ 清单已复制到剪贴板"
                    } label: { Label("复制清单到剪贴板", systemImage: "doc.on.doc") }
                }
            }
            if !note.isEmpty { Section { Text(note).font(.callout) } }
        }
        .navigationTitle("数据维护")
        .confirmationDialog("确定真删全部已下架视频？", isPresented: $confirmPurge, titleVisibility: .visible) {
            Button("确认真删", role: .destructive) { Task { await purge() } }
            Button("取消", role: .cancel) {}
        }
    }

    private func purge() async {
        let rows = await AdminAPI.restRows("rest/v1/videos", query: [
            URLQueryItem(name: "removed", value: "eq.true"),
            URLQueryItem(name: "select", value: "video_id"),
            URLQueryItem(name: "limit", value: "1000"),
        ])
        let ids = rows.map { adminStr($0, "video_id") }.filter { !$0.isEmpty }
        if ids.isEmpty { note = "没有已下架的视频"; return }
        var deleted = 0
        for chunk in stride(from: 0, to: ids.count, by: 100) {
            deleted += await AdminAPI.deleteVideos(ids: Array(ids[chunk..<min(chunk + 100, ids.count)]))
        }
        note = "✅ 已真删 \(deleted) / \(ids.count) 条"
    }

    private func exportList() async {
        let rows = await AdminAPI.restRows("rest/v1/videos", query: [
            URLQueryItem(name: "select", value: "video_id,title,author,views,source_section"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "1000"),
        ])
        let data = (try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted])) ?? Data()
        exportText = String(data: data, encoding: .utf8) ?? ""
        note = "已生成 \(rows.count) 条清单，点下面分享保存"
    }
}

// MARK: - 用户设备信息 (每位用户上报的设备资料, 按用户分组、点开看明细)
struct AdminDevicesView: View {
    struct DevRow: Decodable, Identifiable {
        var username: String?
        var device_id: String?
        var model: String?
        var system_version: String?
        var app_version: String?
        var locale: String?
        var timezone: String?
        var screen: String?
        var battery: Int?
        var storage: String?
        var network: String?
        var updated_at: String?
        var id: String { (username ?? "") + "|" + (device_id ?? "") }
        var seenText: String { String((updated_at ?? "").prefix(16)).replacingOccurrences(of: "T", with: " ") }
    }

    @State private var rows: [DevRow] = []
    @State private var loaded = false

    private var users: [String] {
        Array(Set(rows.map { $0.username ?? "?" })).sorted()
    }

    var body: some View {
        List {
            if loaded && rows.isEmpty {
                Text("还没有设备上报（用户打开新版 App 登录后会自动上报一次）")
                    .foregroundColor(.secondary)
            }
            ForEach(users, id: \.self) { u in
                Section("@" + u) {
                    ForEach(rows.filter { ($0.username ?? "?") == u }) { d in
                        DisclosureGroup {
                            infoRow("设备型号", d.model)
                            infoRow("系统版本", d.system_version)
                            infoRow("App 版本", d.app_version)
                            infoRow("设备 ID", d.device_id)
                            infoRow("时区", d.timezone)
                            infoRow("语言地区", d.locale)
                            infoRow("屏幕分辨率", d.screen)
                            infoRow("电量", d.battery.map { "\($0)%" })
                            infoRow("存储空间", d.storage)
                            infoRow("网络类型", d.network)
                            infoRow("最后上报", d.seenText)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.model ?? "未知设备")
                                    .font(.subheadline.weight(.semibold))
                                Text((d.system_version ?? "") + " · 最后上报 " + d.seenText)
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("用户设备信息")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func infoRow(_ k: String, _ v: String?) -> some View {
        HStack {
            Text(k).foregroundColor(.secondary)
            Spacer()
            Text(v ?? "—").multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    private func load() async {
        let rows: [DevRow]? = try? await SB.rpc("admin_devices", params: [
            "p_token": Session.shared.loginToken])
        self.rows = rows ?? []
        loaded = true
    }
}

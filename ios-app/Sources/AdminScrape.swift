import SwiftUI
import UIKit

// 由 AdminOps.swift 拆分 (v5.2: 每个功能一个文件, 方便定位问题)

struct AuthorScrapeForm: View {
    var presetAuthor: String = ""
    @EnvironmentObject var session: Session
    @State private var authors = ""
    @State private var maxPages = 5
    @State private var note = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("🎯 按作者抓取").font(.headline)
            TextField("作者名（多个用逗号或换行分隔，最多 10 个）", text: $authors)
                .autocorrectionDisabled()
            Stepper("每位作者翻页：\(maxPages) 页", value: $maxPages, in: 1...20)
            Button(busy ? "触发中…" : "开始作者抓") { Task { await run() } }
                .disabled(busy || authors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if !note.isEmpty { Text(note).font(.caption).foregroundColor(.secondary) }
            Text("云端按作者去源站逐页抓卡片入库并解析直链，约几分钟见效。")
                .font(.caption2).foregroundColor(.secondary)
        }
        .onAppear { if authors.isEmpty { authors = presetAuthor } }
    }

    private func run() async {
        let token = session.ghToken
        guard !token.isEmpty else { note = "❌ 还没有 GitHub 令牌"; return }
        busy = true
        let list = authors.split(whereSeparator: { ",，、\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let ok = await GitHub.dispatchWorkflow("author-scrape.yml", inputs: [
            "authors": Array(list.prefix(10)).joined(separator: ","),
            "max_pages": String(maxPages),
            "resolve": "300",
        ], token: token)
        note = ok ? "✅ 已触发，云端开始抓 \(list.count) 位作者" : "❌ 触发失败（令牌权限/工作流）"
        busy = false
    }
}

struct AdminScrapeView: View {
    @EnvironmentObject var session: Session
    @State private var note = ""
    @State private var statusRows: [[String: Any]] = []

    private let modes: [(String, String)] = [
        ("full", "完整抓取"), ("resolve", "只解析直链"), ("deep", "深挖（作者/ID扫段）"),
        ("test", "连通性自检"), ("hsex", "只抓 Hsex"), ("iwara", "只抓 Iwara"),
    ]

    var body: some View {
        List {
            Section("抓取模式") {
                ForEach(modes, id: \.0) { m in
                    Button(m.1) { Task { await dispatch(mode: m.0) } }
                }
                if !note.isEmpty { Text(note).font(.caption) }
            }
            Section { AuthorScrapeForm() }
            Section("补数任务") {
                Button("补文案（标题/作者）") { Task { await dispatchWorkflow("text-backfill.yml", ["limit": "120"]) } }
                Button("补 MP4 直链") { Task { await dispatchWorkflow("mp4-backfill.yml", ["batch": "200"]) } }
            }
            Section("最近抓取状态") {
                if statusRows.isEmpty { Text("暂无").foregroundColor(.secondary) }
                ForEach(Array(statusRows.enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(r.keys.sorted()), id: \.self) { k in
                            Text("\(k): \(adminStr(r, k))").font(.caption2)
                        }
                    }
                }
            }
        }
        .navigationTitle("爬虫控制台")
        .task { await loadStatus() }
    }

    private func loadStatus() async {
        statusRows = await AdminAPI.restRows("rest/v1/scrape_status", query: [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "2"),
        ])
    }

    private func dispatch(mode: String) async {
        let token = session.ghToken
        guard !token.isEmpty else { note = "❌ 还没有 GitHub 令牌"; return }
        let ok = await GitHub.dispatch(mode: mode, token: token)
        note = ok ? "✅ 已触发 \(mode)" : "❌ 触发失败"
    }

    private func dispatchWorkflow(_ file: String, _ inputs: [String: String]) async {
        let token = session.ghToken
        guard !token.isEmpty else { note = "❌ 还没有 GitHub 令牌"; return }
        let ok = await GitHub.dispatchWorkflow(file, inputs: inputs, token: token)
        note = ok ? "✅ 已触发 \(file)" : "❌ 触发失败"
    }
}

// MARK: - 数据维护

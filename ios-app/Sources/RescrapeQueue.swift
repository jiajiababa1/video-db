import SwiftUI

/// 待重爬队列 (站主专属): 失效链接排队重解析的存量 + 一键触发解析任务
struct RescrapeQueueView: View {
    @EnvironmentObject var session: Session
    @State private var rows: [[String: Any]] = []
    @State private var total: Int? = nil
    @State private var note = ""
    @State private var busy = false

    var body: some View {
        List {
            Section("队列概况") {
                HStack {
                    Text("待重爬总数")
                    Spacer()
                    Text(total.map { "\($0)" } ?? "—")
                        .foregroundColor(.secondary)
                }
                Button {
                    Task { await dispatch() }
                } label: {
                    Label(busy ? "触发中…" : "立即触发一轮解析", systemImage: "play.circle")
                }
                .disabled(busy || session.ghToken.isEmpty)
                if session.ghToken.isEmpty {
                    Text("需要先在「令牌配置」里填好 GitHub 令牌才能远程触发")
                        .font(.caption).foregroundColor(.orange)
                }
                if !note.isEmpty {
                    Text(note).font(.caption).foregroundColor(.secondary)
                }
            }
            Section("排队最久的 \(rows.count) 条") {
                if rows.isEmpty {
                    Text("队列是空的").foregroundColor(.secondary)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(adminStr(r, "title").isEmpty ? "(无标题)" : adminStr(r, "title"))
                            .font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        Text("@\(adminStr(r, "author")) · \(adminStr(r, "video_id"))")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("待重爬队列")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        total = await AdminAPI.restCount("rest/v1/videos", query: [
            URLQueryItem(name: "select", value: "video_id"),
            URLQueryItem(name: "needs_rescrape", value: "eq.true"),
        ])
        rows = await AdminAPI.restRows("rest/v1/videos", query: [
            URLQueryItem(name: "select", value: "video_id,title,author,updated_at"),
            URLQueryItem(name: "needs_rescrape", value: "eq.true"),
            URLQueryItem(name: "order", value: "updated_at.asc"),
            URLQueryItem(name: "limit", value: "60"),
        ])
    }

    private func dispatch() async {
        busy = true
        let ok = await GitHub.dispatch(mode: "resolve", token: session.ghToken)
        note = ok ? "已触发，爬虫开始解析队列（几分钟后刷新看数量变化）" : "触发失败：令牌可能无效"
        busy = false
    }
}

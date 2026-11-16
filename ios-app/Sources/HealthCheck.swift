import SwiftUI

/// 健康巡检 (站主专属): 一屏看全站关键指标是否正常
struct HealthCheckView: View {
    struct Check: Identifiable {
        var id: String { name }
        var name: String
        var value: String
        var ok: Bool
    }

    @State private var checks: [Check] = []
    @State private var loading = true

    var body: some View {
        List {
            if loading {
                HStack { ProgressView(); Text("巡检中…").foregroundColor(.secondary) }
            }
            ForEach(checks) { c in
                HStack {
                    Text(c.ok ? "✅" : "⚠️")
                    Text(c.name)
                    Spacer()
                    Text(c.value).foregroundColor(.secondary)
                }
            }
            if !loading {
                Text("标准：可播率 ≥40%、待重爬 ≤3000 算正常。每天凌晨的核心备份与每小时排行榜刷新由数据库定时任务自动跑。")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .navigationTitle("健康巡检")
        .task { await run() }
        .refreshable { await run() }
    }

    private func run() async {
        loading = true
        let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        func count(_ path: String, _ extra: [URLQueryItem]) async -> Int? {
            await AdminAPI.restCountExact(path, query: [URLQueryItem(name: "select", value: "id")] + extra)
        }
        async let total = AdminAPI.restCount("rest/v1/videos", query: [URLQueryItem(name: "select", value: "video_id")])
        async let playable = AdminAPI.restCount("rest/v1/videos", query: [
            URLQueryItem(name: "select", value: "video_id"), URLQueryItem(name: "has_mp4", value: "eq.true")])
        async let rescrape = AdminAPI.restCount("rest/v1/videos", query: [
            URLQueryItem(name: "select", value: "video_id"), URLQueryItem(name: "needs_rescrape", value: "eq.true")])
        async let todayVideos = AdminAPI.restCount("rest/v1/videos", query: [
            URLQueryItem(name: "select", value: "video_id"), URLQueryItem(name: "created_at", value: "gte." + today)])
        async let todayComments = count("rest/v1/video_comments", [URLQueryItem(name: "created_at", value: "gte." + today)])
        async let todayDanmaku = count("rest/v1/video_danmaku", [URLQueryItem(name: "created_at", value: "gte." + today)])
        async let users = AdminAPI.restCountExact("rest/v1/user_accounts", query: [URLQueryItem(name: "select", value: "username")])
        async let sessions = AdminAPI.restCountExact("rest/v1/sessions", query: [URLQueryItem(name: "select", value: "id")])
        let (t, p, r, tv, tc, td, u, s) = await (total, playable, rescrape, todayVideos, todayComments, todayDanmaku, users, sessions)
        var out: [Check] = []
        if let t = t, let p = p, t > 0 {
            let rate = p * 100 / t
            out.append(Check(name: "可播率", value: "\(rate)%（\(p)/\(t)）", ok: rate >= 40))
        } else {
            out.append(Check(name: "可播率", value: "读取失败", ok: false))
        }
        out.append(Check(name: "待重爬", value: r.map { "\($0)" } ?? "读取失败", ok: (r ?? Int.max) <= 3000))
        out.append(Check(name: "今日新增视频", value: tv.map { "\($0)" } ?? "—", ok: (tv ?? 0) > 0))
        out.append(Check(name: "今日评论", value: tc.map { "\($0)" } ?? "—", ok: true))
        out.append(Check(name: "今日弹幕", value: td.map { "\($0)" } ?? "—", ok: true))
        out.append(Check(name: "注册用户", value: u.map { "\($0)" } ?? "—", ok: true))
        out.append(Check(name: "活跃会话", value: s.map { "\($0)" } ?? "—", ok: true))
        checks = out
        loading = false
    }
}

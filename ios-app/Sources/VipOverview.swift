import SwiftUI

/// VIP 总览 (站主专属): 全部 VIP 记录 (谁、什么等级、到期时间、来源)
struct VipOverviewView: View {
    @State private var rows: [[String: Any]] = []

    private var levelCounts: [(String, Int)] {
        var m: [String: Int] = [:]
        for r in rows {
            let lv = adminStr(r, "level").isEmpty ? adminStr(r, "vip_level") : adminStr(r, "level")
            if !lv.isEmpty { m[lv, default: 0] += 1 }
        }
        return m.sorted { $0.value > $1.value }
    }

    var body: some View {
        List {
            Section("等级分布") {
                if levelCounts.isEmpty {
                    Text("暂无 VIP 记录").foregroundColor(.secondary)
                }
                ForEach(levelCounts, id: \.0) { lv, n in
                    HStack {
                        Text(lv)
                        Spacer()
                        Text("\(n) 人").foregroundColor(.secondary)
                    }
                }
            }
            Section("全部记录 (\(rows.count))") {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("@" + who(r)).font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Text(adminStr(r, "level").isEmpty ? adminStr(r, "vip_level") : adminStr(r, "level"))
                                .font(.caption).foregroundColor(Theme.gold2)
                        }
                        Text(detail(r)).font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("VIP 总览")
        .task { await load() }
        .refreshable { await load() }
    }

    private func who(_ r: [String: Any]) -> String {
        let u = adminStr(r, "username")
        return u.isEmpty ? (adminStr(r, "device_id").isEmpty ? "?" : "设备 " + adminStr(r, "device_id")) : u
    }

    private func detail(_ r: [String: Any]) -> String {
        var parts: [String] = []
        let exp = adminStr(r, "expires_at")
        parts.append(exp.isEmpty ? "永久" : "到期 " + String(exp.prefix(10)))
        let src = adminStr(r, "source")
        if !src.isEmpty { parts.append("来源 " + src) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        rows = await AdminAPI.restRows("rest/v1/user_vips", query: [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "200"),
        ])
    }
}

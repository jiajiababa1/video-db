import SwiftUI
import UIKit

// 由 Features21.swift 拆分 (v5.2: 每个功能一个文件, 方便定位问题)

struct LeaderboardView: View {
    struct Row: Decodable, Identifiable {
        var name: String?
        var videos_count: Int?
        var total_views: Int?
        var id: String { name ?? "" }
    }

    @State private var rows: [Row] = []
    @State private var loaded = false

    var body: some View {
        List {
            if loaded && rows.isEmpty {
                Text("榜单生成中, 稍后再来看看")
                    .foregroundColor(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                NavigationLink {
                    AuthorView(name: r.name ?? "")
                } label: {
                    HStack(spacing: 12) {
                        Text("\(i + 1)")
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundColor(i < 3 ? Theme.gold2 : Theme.sub)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name ?? "")
                                .font(.system(size: 14.5, weight: .semibold))
                            Text("\(r.videos_count ?? 0) 条视频")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("\(r.total_views ?? 0) 观看")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("作者排行榜")
        .task {
            if !loaded {
                loaded = true
                await load()
            }
        }
    }

    private func load() async {
        let (rs, _): ([Row], Int?) = (try? await SB.get(
            "rest/v1/leaderboard_authors_cache",
            query: [
                URLQueryItem(name: "select", value: "name,videos_count,total_views"),
                URLQueryItem(name: "order", value: "total_views.desc"),
                URLQueryItem(name: "limit", value: "30"),
            ])) ?? ([], nil)
        rows = rs
    }
}

// MARK: - 我的设备

import SwiftUI
import UIKit

// 由 Features21.swift 拆分 (v5.2: 每个功能一个文件, 方便定位问题)

struct SitePagesListView: View {
    struct Row: Decodable, Identifiable {
        var slug: String?
        var title: String?
        var id: String { slug ?? "" }
    }

    @State private var rows: [Row] = []
    @State private var loaded = false

    var body: some View {
        List {
            if loaded && rows.isEmpty {
                Text("还没有站内页面\n站主在管理面板「站内页管理」里新建后会出现在这里")
                    .foregroundColor(.secondary)
            }
            ForEach(rows) { r in
                NavigationLink {
                    SitePageView(slug: r.slug ?? "", fallbackTitle: r.title ?? "")
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.title ?? "")
                            .font(.system(size: 14.5, weight: .semibold))
                        Text("/" + (r.slug ?? ""))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("站内页面")
        .task {
            if !loaded {
                loaded = true
                await load()
            }
        }
    }

    private func load() async {
        let (rs, _): ([Row], Int?) = (try? await SB.get(
            "rest/v1/site_pages",
            query: [
                URLQueryItem(name: "select", value: "slug,title"),
                URLQueryItem(name: "order", value: "slug.asc"),
                URLQueryItem(name: "limit", value: "100"),
            ])) ?? ([], nil)
        rows = rs
    }
}

// MARK: - 真点赞 API

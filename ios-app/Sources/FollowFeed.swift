import SwiftUI
import UIKit

// 由 Features21.swift 拆分 (v5.2: 每个功能一个文件, 方便定位问题)

/// 关注分组 (跟账号走, 存 UserDefaults 的本账号键, 不进 Library 的 Persist 结构):
/// order = 分组名顺序, map = 作者名 → 分组名 (不在 map 里 = 未分组)
enum FollowGroups {
    struct Store: Codable {
        var order: [String] = []
        var map: [String: String] = [:]
    }

    private static var key: String { "vdb_follow_groups_" + (Session.shared.username ?? "anon") }

    static func load() -> Store {
        guard let raw = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(Store.self, from: raw) else { return Store() }
        return s
    }

    static func save(_ s: Store) {
        if let raw = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(raw, forKey: key)
        }
    }
}

// MARK: - 关注更新流

struct FollowFeedView: View {
    @EnvironmentObject var library: Library
    @State private var selGroup: String? = nil
    @State private var groups = FollowGroups.load()

    private var groupNames: [String] {
        groups.order.filter { g in library.follows.contains { groups.map[$0] == g } }
    }

    private var shownFollows: [String] {
        guard let g = selGroup else { return library.follows }
        return library.follows.filter { groups.map[$0] == g }
    }

    var body: some View {
        if library.follows.isEmpty {
            VStack(spacing: 10) {
                Text("还没关注任何作者")
                    .font(.system(size: 15, weight: .bold))
                Text("在视频页点「+ 关注」后, 他们的新视频会出现在这里")
                    .font(.footnote).foregroundColor(Theme.sub)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("关注更新")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            VStack(spacing: 0) {
                if !groupNames.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            groupChip("全部", selGroup == nil) { selGroup = nil }
                            ForEach(groupNames, id: \.self) { g in
                                groupChip(g, selGroup == g) { selGroup = g }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .background(Theme.bg)
                }
                RemoteFeedView(navTitle: "关注更新", emptyText: "关注的作者还没有新视频") { _ in
                    "&removed=not.is.true&author=" + pgInList(shownFollows) + playableOrFilter
                }
                .id(selGroup ?? "__all")
            }
            .background(Theme.bg.ignoresSafeArea())
            .onAppear { groups = FollowGroups.load() }
        }
    }

    private func groupChip(_ text: String, _ active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(active ? Theme.gold : Theme.surface2)
                .foregroundColor(active ? .black : Theme.text)
                .cornerRadius(99)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 今日新增

import Foundation
import SwiftUI

/// 消息中心 (#5): APNs 真推送对未签名 App 不可用, 改做 App 内聚合未读 —
/// 私信未读 / 好友申请 / 入群待审 / 作品待审 / 新公告, 汇总到 Tab 角标。
/// 每次打开 App、登录状态变化、回到前台时刷新。
final class NoticeCenter: ObservableObject {
    static let shared = NoticeCenter()

    @Published var dmUnread = 0
    @Published var friendReqs = 0
    @Published var joinReqs = 0
    @Published var workReqs = 0
    @Published var newAnnounces: [String] = []   // 未读公告标题

    var socialBadge: Int { dmUnread + friendReqs + joinReqs }
    var meBadge: Int { workReqs + newAnnounces.count }
    var total: Int { socialBadge + meBadge }

    private let seenKey = "vdb_seen_announce_ids"

    func refresh(session: Session) async {
        guard session.isLoggedIn, let me = session.username else {
            await MainActor.run {
                self.dmUnread = 0; self.friendReqs = 0; self.joinReqs = 0
                self.workReqs = 0; self.newAnnounces = []
            }
            return
        }
        async let dm = DMAPI.unread(token: session.loginToken)
        async let fr = AdminAPI.restCount("rest/v1/friends", query: [
            URLQueryItem(name: "user2", value: "eq." + me),
            URLQueryItem(name: "status", value: "eq.pending"),
            URLQueryItem(name: "select", value: "user1"),
        ])
        async let jr = countJoinReqs(me: me)
        async let wr = session.isOwner ? AdminAPI.restCount("rest/v1/work_requests", query: [
            URLQueryItem(name: "status", value: "eq.pending"),
            URLQueryItem(name: "select", value: "id"),
        ]) : nil
        async let ann = fetchAnnounces()
        let (d, f, j, w, a) = await (dm, fr, jr, wr, ann)
        await MainActor.run {
            self.dmUnread = d
            self.friendReqs = f ?? 0
            self.joinReqs = j
            self.workReqs = w ?? 0
            self.newAnnounces = a
        }
    }

    private func countJoinReqs(me: String) async -> Int {
        let groups = await AdminAPI.restRows("rest/v1/board_groups", query: [
            URLQueryItem(name: "owner", value: "eq." + me),
            URLQueryItem(name: "select", value: "id"),
            URLQueryItem(name: "limit", value: "100"),
        ])
        let ids = groups.compactMap { ($0["id"] as? NSNumber)?.intValue }
        guard !ids.isEmpty else { return 0 }
        let list = "(" + ids.map(String.init).joined(separator: ",") + ")"
        return await AdminAPI.restCount("rest/v1/board_join_reqs", query: [
            URLQueryItem(name: "group_id", value: "in." + list),
            URLQueryItem(name: "status", value: "eq.pending"),
            URLQueryItem(name: "select", value: "id"),
        ]) ?? 0
    }

    private func fetchAnnounces() async -> [String] {
        let rows = await AdminAPI.restRows("rest/v1/announcements", query: [
            URLQueryItem(name: "is_active", value: "is.true"),
            URLQueryItem(name: "select", value: "id,title"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "3"),
        ])
        let seen = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
        return rows.filter { !seen.contains(adminStr($0, "id")) }
                   .map { adminStr($0, "title") }
                   .filter { !$0.isEmpty }
    }

    func markAnnouncesSeen() async {
        let rows = await AdminAPI.restRows("rest/v1/announcements", query: [
            URLQueryItem(name: "is_active", value: "is.true"),
            URLQueryItem(name: "select", value: "id"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "3"),
        ])
        let ids = rows.map { adminStr($0, "id") }.filter { !$0.isEmpty }
        UserDefaults.standard.set(ids, forKey: seenKey)
        await MainActor.run { self.newAnnounces = [] }
    }
}

/// 消息中心页: 汇总所有待处理事项, 点行直达处理位置
struct NoticeView: View {
    @EnvironmentObject var session: Session
    @ObservedObject private var center = NoticeCenter.shared

    var body: some View {
        List {
            if center.total == 0 {
                Text("没有待处理的消息 🎉").foregroundColor(.secondary)
            }
            if center.dmUnread > 0 {
                row("私信未读", "\(center.dmUnread) 条", "envelope.badge")
                Text("在「好友」页点开对应好友的私信即可清掉未读")
                    .font(.caption2).foregroundColor(.secondary)
            }
            if center.friendReqs > 0 {
                row("好友申请", "\(center.friendReqs) 人等你同意", "person.badge.plus")
                Text("在「好友」页顶部处理").font(.caption2).foregroundColor(.secondary)
            }
            if center.joinReqs > 0 {
                row("入群待审", "\(center.joinReqs) 条申请", "person.3")
                Text("进对应板块群的群管理里通过").font(.caption2).foregroundColor(.secondary)
            }
            if center.workReqs > 0 {
                NavigationLink {
                    WorksView()
                } label: {
                    row("作品待审", "\(center.workReqs) 件等你审核", "photo.stack")
                }
            }
            if !center.newAnnounces.isEmpty {
                Section("新公告") {
                    ForEach(center.newAnnounces, id: \.self) { t in
                        Text(t).font(.callout)
                    }
                    Button("标为已读") { Task { await center.markAnnouncesSeen() } }
                }
            }
        }
        .navigationTitle("消息中心")
        .task { await center.refresh(session: session) }
    }

    private func row(_ title: String, _ detail: String, _ icon: String) -> some View {
        HStack {
            Image(systemName: icon).foregroundColor(.orange)
            Text(title)
            Spacer()
            Text(detail).foregroundColor(.secondary)
        }
    }
}

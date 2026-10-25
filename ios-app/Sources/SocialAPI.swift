import Foundation

// MARK: - 社交数据模型 (与网站表结构一致)

struct FriendRow: Codable, Identifiable {
    var user1: String
    var user2: String
    var status: String
    var created_at: String?
    var id: String { user1 + "|" + user2 + "|" + status }
}

struct BoardGroup: Codable, Identifiable {
    var id: Int
    var name: String?
    var avatar_url: String?
    var owner: String?
    var entry_mode: String?
    var entry_question: String?
    var status: String?
    var mute_all: Bool?
    var created_at: String?
}

struct BoardMember: Codable {
    var group_id: Int
    var username: String
    var role: String?
    var muted_until: String?
}

struct BoardMessage: Codable, Identifiable {
    var id: Int?
    var group_id: Int?
    var sender: String?
    var content: String?
    var created_at: String?

    var timeText: String {
        guard let c = created_at else { return "" }
        return String(c.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }
}

struct WorkItem: Codable, Identifiable {
    var id: Int
    var title: String?
    var file_url: String?
    var cover_url: String?
    var description: String?
    var author: String?
    var created_at: String?
}

enum SocialAPI {
    static func myFriendRows(me: String) async -> [FriendRow] {
        async let a: ([FriendRow], Int?) = (try? await SB.get("rest/v1/friends", query: [
            URLQueryItem(name: "user1", value: "eq." + me),
            URLQueryItem(name: "order", value: "created_at.desc"),
        ])) ?? ([], nil)
        async let b: ([FriendRow], Int?) = (try? await SB.get("rest/v1/friends", query: [
            URLQueryItem(name: "user2", value: "eq." + me),
            URLQueryItem(name: "order", value: "created_at.desc"),
        ])) ?? ([], nil)
        return await (a.0 + b.0)
    }

    static func userExists(_ name: String) async -> Bool {
        let (rows, _): ([[String: String]], Int?) = (try? await SB.get("rest/v1/user_accounts", query: [
            URLQueryItem(name: "username", value: "eq." + name),
            URLQueryItem(name: "select", value: "username"),
            URLQueryItem(name: "limit", value: "1"),
        ])) ?? ([], nil)
        return !rows.isEmpty
    }

    static func sendRequest(me: String, to: String) async -> Bool {
        do {
            try await SB.insert("rest/v1/friends",
                body: ["user1": me, "user2": to, "status": "pending"])
            return true
        } catch { return false }
    }

    static func accept(me: String, from: String) async {
        try? await SB.patch("rest/v1/friends", query: [
            URLQueryItem(name: "user1", value: "eq." + from),
            URLQueryItem(name: "user2", value: "eq." + me),
        ], body: ["status": "accepted"])
    }

    static func removeRow(a: String, b: String) async {
        try? await SB.delete("rest/v1/friends", query: [
            URLQueryItem(name: "user1", value: "eq." + a),
            URLQueryItem(name: "user2", value: "eq." + b),
        ])
        try? await SB.delete("rest/v1/friends", query: [
            URLQueryItem(name: "user1", value: "eq." + b),
            URLQueryItem(name: "user2", value: "eq." + a),
        ])
    }

    static func activeGroups() async -> [BoardGroup] {
        let (rows, _): ([BoardGroup], Int?) = (try? await SB.get("rest/v1/board_groups", query: [
            URLQueryItem(name: "status", value: "eq.active"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "60"),
        ])) ?? ([], nil)
        return rows
    }

    static func myMemberships(me: String) async -> [BoardMember] {
        let (rows, _): ([BoardMember], Int?) = (try? await SB.get("rest/v1/board_members", query: [
            URLQueryItem(name: "username", value: "eq." + me),
            URLQueryItem(name: "select", value: "group_id,username,role,muted_until"),
        ])) ?? ([], nil)
        return rows
    }

    static func messages(groupId: Int) async -> [BoardMessage] {
        let (rows, _): ([BoardMessage], Int?) = (try? await SB.get("rest/v1/board_messages", query: [
            URLQueryItem(name: "group_id", value: "eq." + String(groupId)),
            URLQueryItem(name: "order", value: "created_at.asc"),
            URLQueryItem(name: "limit", value: "100"),
        ])) ?? ([], nil)
        return rows
    }

    static func sendMessage(groupId: Int, sender: String, content: String) async -> Bool {
        do {
            try await SB.insert("rest/v1/board_messages",
                body: ["group_id": groupId, "sender": sender,
                       "content": String(content.prefix(2000))])
            return true
        } catch { return false }
    }

    static func joinOpen(groupId: Int, me: String) async -> Bool {
        do {
            try await SB.insert("rest/v1/board_members",
                body: ["group_id": groupId, "username": me, "role": "member"])
            return true
        } catch { return false }
    }

    static func submitJoinRequest(groupId: Int, me: String, answer: String) async -> Bool {
        do {
            try await SB.insert("rest/v1/board_join_reqs",
                body: ["group_id": groupId, "applicant": me, "answer": answer, "status": "pending"])
            return true
        } catch { return false }
    }

    struct JoinReq: Codable {
        var group_id: Int?
        var applicant: String?
        var answer: String?
        var status: String?
        var created_at: String?
    }

    static func pendingJoinRequests(groupId: Int) async -> [JoinReq] {
        let (rows, _): ([JoinReq], Int?) = (try? await SB.get("rest/v1/board_join_reqs", query: [
            URLQueryItem(name: "group_id", value: "eq." + String(groupId)),
            URLQueryItem(name: "status", value: "eq.pending"),
            URLQueryItem(name: "order", value: "created_at.asc"),
            URLQueryItem(name: "limit", value: "50"),
        ])) ?? ([], nil)
        return rows
    }

    static func approveJoin(groupId: Int, applicant: String) async {
        try? await SB.patch("rest/v1/board_join_reqs", query: [
            URLQueryItem(name: "group_id", value: "eq." + String(groupId)),
            URLQueryItem(name: "applicant", value: "eq." + applicant),
        ], body: ["status": "approved"])
        _ = await joinOpen(groupId: groupId, me: applicant)
    }

    static func rejectJoin(groupId: Int, applicant: String) async {
        try? await SB.patch("rest/v1/board_join_reqs", query: [
            URLQueryItem(name: "group_id", value: "eq." + String(groupId)),
            URLQueryItem(name: "applicant", value: "eq." + applicant),
        ], body: ["status": "rejected"])
    }

    static func works() async -> [WorkItem] {
        let (rows, _): ([WorkItem], Int?) = (try? await SB.get("rest/v1/works", query: [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "60"),
        ])) ?? ([], nil)
        return rows
    }
}

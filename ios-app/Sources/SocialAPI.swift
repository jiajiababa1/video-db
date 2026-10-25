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

    // MARK: - 群管理 / 建群 (与网站 refreshBoardRoom 的管理语义一致)
    static func groupMembers(groupId: Int) async -> [BoardMember] {
        let (rows, _): ([BoardMember], Int?) = (try? await SB.get("rest/v1/board_members", query: [
            URLQueryItem(name: "group_id", value: "eq." + String(groupId)),
            URLQueryItem(name: "select", value: "group_id,username,role,muted_until"),
            URLQueryItem(name: "limit", value: "200"),
        ])) ?? ([], nil)
        return rows
    }

    static func memberDetail(groupId: Int, me: String) async -> BoardMember? {
        let (rows, _): ([BoardMember], Int?) = (try? await SB.get("rest/v1/board_members", query: [
            URLQueryItem(name: "group_id", value: "eq." + String(groupId)),
            URLQueryItem(name: "username", value: "eq." + me),
            URLQueryItem(name: "select", value: "group_id,username,role,muted_until"),
            URLQueryItem(name: "limit", value: "1"),
        ])) ?? ([], nil)
        return rows.first
    }

    static func setMuted(groupId: Int, user: String, until: String?) async {
        var body: [String: Any] = [:]
        if let u = until { body["muted_until"] = u } else { body["muted_until"] = NSNull() }
        try? await SB.patch("rest/v1/board_members", query: [
            URLQueryItem(name: "group_id", value: "eq." + String(groupId)),
            URLQueryItem(name: "username", value: "eq." + user),
        ], body: body)
    }

    static func kick(groupId: Int, user: String) async {
        try? await SB.delete("rest/v1/board_members", query: [
            URLQueryItem(name: "group_id", value: "eq." + String(groupId)),
            URLQueryItem(name: "username", value: "eq." + user),
        ])
    }

    static func setRole(groupId: Int, user: String, role: String) async {
        try? await SB.patch("rest/v1/board_members", query: [
            URLQueryItem(name: "group_id", value: "eq." + String(groupId)),
            URLQueryItem(name: "username", value: "eq." + user),
        ], body: ["role": role])
    }

    static func setMuteAll(groupId: Int, on: Bool) async {
        try? await SB.patch("rest/v1/board_groups", query: [
            URLQueryItem(name: "id", value: "eq." + String(groupId)),
        ], body: ["mute_all": on])
    }

    static func dissolve(groupId: Int) async {
        try? await SB.patch("rest/v1/board_groups", query: [
            URLQueryItem(name: "id", value: "eq." + String(groupId)),
        ], body: ["status": "dissolved"])
    }

    static func createGroup(name: String, owner: String, mode: String, question: String) async -> Bool {
        do {
            let rows: [BoardGroup] = try await SB.post("rest/v1/board_groups", body: [
                "name": name, "owner": owner, "entry_mode": mode,
                "entry_question": mode == "question" ? question : "",
                "status": "active",
            ])
            guard let g = rows.first else { return false }
            try await SB.insert("rest/v1/board_members",
                body: ["group_id": g.id, "username": owner, "role": "owner"])
            return true
        } catch { return false }
    }

    // MARK: - 作品审核 (站长; 与网站 approveWork/rejectWork 语义一致)
    struct WorkRequest: Codable, Identifiable {
        var id: Int
        var title: String?
        var file_url: String?
        var cover_url: String?
        var description: String?
        var submitter: String?
        var status: String?
        var created_at: String?
    }

    static func pendingWorks() async -> [WorkRequest] {
        let (rows, _): ([WorkRequest], Int?) = (try? await SB.get("rest/v1/work_requests", query: [
            URLQueryItem(name: "status", value: "eq.pending"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "100"),
        ])) ?? ([], nil)
        return rows
    }

    static func approveWork(_ w: WorkRequest) async {
        _ = try? await SB.insert("rest/v1/works", body: [
            "title": w.title ?? "", "file_url": w.file_url ?? "",
            "cover_url": w.cover_url ?? "", "description": w.description ?? "",
            "author": w.submitter ?? "",
        ])
        try? await SB.patch("rest/v1/work_requests", query: [
            URLQueryItem(name: "id", value: "eq." + String(w.id)),
        ], body: ["status": "approved"])
    }

    static func rejectWork(id: Int) async {
        try? await SB.patch("rest/v1/work_requests", query: [
            URLQueryItem(name: "id", value: "eq." + String(id)),
        ], body: ["status": "rejected"])
    }
}

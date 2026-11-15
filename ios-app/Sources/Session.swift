import Foundation
import Combine
import Security

/// 会话敏感令牌存 iOS 钥匙串 (不再明文放 UserDefaults):
/// login_token / gate_token 都走这里; 旧版明文值首次读取时自动迁移进钥匙串并删除明文。
/// 身份权限以服务端 check_session 的回答为准, 本地标志被改也认不回来 (见 validateSession)。
private enum SessionKeychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "vdb.session",
         kSecAttrAccount as String: account]
    }

    static func set(_ value: String, account: String) {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }

    /// 钥匙串优先; 没有则读旧版 UserDefaults 明文并迁移
    static func migrated(account: String, legacyKey: String, defaults: UserDefaults) -> String {
        if let t = get(account), !t.isEmpty { return t }
        if let t = defaults.string(forKey: legacyKey), !t.isEmpty {
            set(t, account: account)
            defaults.removeObject(forKey: legacyKey)
            return t
        }
        return ""
    }
}

/// 已保存账号 (多账号一键切换: 令牌存钥匙串, 点一下直接换, 不用再输密码)
struct SavedAccount: Codable, Identifiable {
    var username: String
    var token: String
    var id: String { username }
}

/// 会话状态: 设备 ID / 门禁 token / 账号登录 (令牌在钥匙串, 其余与网站 localStorage 同构)
final class Session: ObservableObject {
    static let shared = Session()

    @Published var gatePassed: Bool
    @Published var username: String?
    @Published var isAdmin: Bool = false
    @Published var vipLevel: Int = 0
    @Published var savedAccounts: [SavedAccount] = []
    @Published var accountGeneration = 0   // 登录/切换/退出时 +1, RootView 据此重拉云端数据
    @Published var myUserId: Int? = nil    // 自己的用户 ID: 站主只认 id == 1
    @Published var isBanned: Bool = false  // 被封禁: 全站禁言, 只能每小时申诉一次
    @Published var appealWaitSeconds: Int = 0  // 距下次可申诉的剩余秒数
    @Published var sessionExpired: Bool = false  // 服务端明确判令牌失效 (僵尸登录态): RootView 弹窗让用户重登

    private let d = UserDefaults.standard

    init() {
        gatePassed = !SessionKeychain.migrated(account: "gate_token", legacyKey: "vid_gate_token", defaults: d).isEmpty
        username = d.string(forKey: "login_user")
        isAdmin = d.bool(forKey: "login_is_admin")
        vipLevel = d.integer(forKey: "login_vip")
        let storedId = d.integer(forKey: "login_user_id")
        myUserId = storedId > 0 ? storedId : nil
        savedAccounts = Self.loadSavedAccounts()
        // 当前已登录的账号不在列表里 (老版本升上来) → 补存一次
        if let u = username, !loginToken.isEmpty,
           !savedAccounts.contains(where: { $0.username == u }) {
            savedAccounts.append(SavedAccount(username: u, token: loginToken))
            persistSavedAccounts()
        }
    }

    // MARK: - 多账号保存

    private static func loadSavedAccounts() -> [SavedAccount] {
        guard let s = SessionKeychain.get("accounts_v1"),
              let data = s.data(using: .utf8),
              let arr = try? JSONDecoder().decode([SavedAccount].self, from: data) else { return [] }
        return arr
    }

    private func persistSavedAccounts() {
        if let data = try? JSONEncoder().encode(savedAccounts),
           let s = String(data: data, encoding: .utf8) {
            SessionKeychain.set(s, account: "accounts_v1")
        }
    }

    private func rememberAccount() {
        guard let u = username, !loginToken.isEmpty else { return }
        if let i = savedAccounts.firstIndex(where: { $0.username == u }) {
            savedAccounts[i].token = loginToken
        } else {
            savedAccounts.append(SavedAccount(username: u, token: loginToken))
        }
        persistSavedAccounts()
    }

    /// 一键切换账号: 换上已保存的令牌, 身份随后以服务端校验为准刷新
    func switchAccount(to name: String) async {
        guard let acc = savedAccounts.first(where: { $0.username == name }),
              name != username else { return }
        d.set(acc.username, forKey: "login_user")
        storeLoginToken(acc.token)
        d.removeObject(forKey: "login_is_admin")
        d.removeObject(forKey: "login_vip")
        username = acc.username
        isAdmin = false
        vipLevel = 0
        myUserId = nil
        d.removeObject(forKey: "gh_token")
        d.removeObject(forKey: "login_user_id")
        await validateSession()
        accountGeneration += 1
    }

    /// 从已保存列表移除账号 (移除的是当前账号 = 完整退出登录)
    func removeAccount(_ name: String) {
        if name == username {
            logout()
            return
        }
        savedAccounts.removeAll { $0.username == name }
        persistSavedAccounts()
    }

    /// 退出当前账号但保留在列表里: 不通知服务端作废令牌, 之后可一键切回
    func signOutLocal() {
        d.removeObject(forKey: "login_user")
        SessionKeychain.remove("login_token")
        d.removeObject(forKey: "login_token")
        d.removeObject(forKey: "login_is_admin")
        d.removeObject(forKey: "login_vip")
        d.removeObject(forKey: "sb_token")
        d.removeObject(forKey: "gh_token")
        d.removeObject(forKey: "login_user_id")
        username = nil; isAdmin = false; vipLevel = 0; myUserId = nil
        accountGeneration += 1
    }

    var deviceId: String {
        if let s = d.string(forKey: "vid_device_id"), !s.isEmpty { return s }
        let s = "dev-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
            + String(Int(Date().timeIntervalSince1970))
        d.set(s, forKey: "vid_device_id")
        return s
    }

    var gateToken: String { SessionKeychain.migrated(account: "gate_token", legacyKey: "vid_gate_token", defaults: d) }
    var loginToken: String { SessionKeychain.migrated(account: "login_token", legacyKey: "login_token", defaults: d) }

    private func storeLoginToken(_ t: String) {
        SessionKeychain.set(t, account: "login_token")
        d.removeObject(forKey: "login_token")
    }
    var isLoggedIn: Bool { username != nil && !loginToken.isEmpty }
    /// 站主闸门: 只认用户 ID == 1 (kuo 本人)。
    /// 旧版用"本机存有 gh 令牌"判断, 令牌残留会让同一手机上的其他账号全被认成站主, 已废弃;
    /// gh 令牌现在只是调用 GitHub 的凭据, 不再代表身份。
    var isOwner: Bool { myUserId == 1 }

    var ghToken: String {
        get { d.string(forKey: "gh_token") ?? "" }
        set { d.set(newValue, forKey: "gh_token") }
    }

    /// Supabase 管理令牌 (与网站 sb_token 同物, 跟账号云同步)
    var sbToken: String {
        get { d.string(forKey: "sb_token") ?? "" }
        set { d.set(newValue, forKey: "sb_token") }
    }

    // MARK: - 门禁
    func verifyPasscode(_ code: String) async -> String? {
        struct R: Decodable { var ok: Bool?; var token: String?; var message: String? }
        do {
            let rows: [R] = try await SB.rpc("verify_passcode",
                params: ["p_code": code, "p_device_id": deviceId])
            guard let r = rows.first, r.ok == true, let t = r.token else {
                return rows.first?.message ?? "口令不正确"
            }
            SessionKeychain.set(t, account: "gate_token")
            d.removeObject(forKey: "vid_gate_token")
            gatePassed = true
            return nil
        } catch {
            return "网络错误: \(error.localizedDescription)"
        }
    }

    // MARK: - 账号
    func login(username u: String, password p: String) async -> String? {
        struct R: Decodable { var ok: Bool?; var token: String?; var message: String?; var is_admin: Bool?; var vip_level: FlexInt? }
        do {
            let rows: [R] = try await SB.rpc("login_account",
                params: ["p_username": u, "p_password": p, "p_device_id": deviceId])
            guard let r = rows.first, r.ok == true, let t = r.token else {
                return rows.first?.message ?? "登录失败"
            }
            d.set(u, forKey: "login_user")
            storeLoginToken(t)
            d.set(r.is_admin ?? false, forKey: "login_is_admin")
            d.set(r.vip_level?.value ?? 0, forKey: "login_vip")
            username = u; isAdmin = r.is_admin ?? false; vipLevel = r.vip_level?.value ?? 0
            rememberAccount()
            sessionExpired = false
            accountGeneration += 1
            await fetchMyId()
            // 派生云端配置解密密钥并取回跟账号走的令牌 (gh/sb token)
            if let key = TokenVault.deriveKey(password: p) {
                TokenVault.saveKey(key, for: u)
            }
            await TokenVault.pullTokens(session: self)
            return nil
        } catch {
            return "网络错误: \(error.localizedDescription)"
        }
    }

    /// 注册新账号 (#8): 验证码由 xxapi 生成图片, 服务端在 register_account 内校验;
    /// 成功直接返回 token (与网站一致, 注册即登录)。
    func register(username u: String, password p: String, captchaId: String, captchaKey: String) async -> String? {
        struct R: Decodable { var ok: Bool?; var token: String?; var message: String?; var is_admin: Bool?; var vip_level: FlexInt? }
        do {
            let rows: [R] = try await SB.rpc("register_account",
                params: ["p_username": u, "p_password": p, "p_device_id": deviceId,
                         "p_captcha_id": captchaId, "p_captcha_key": captchaKey])
            guard let r = rows.first, r.ok == true, let t = r.token else {
                return rows.first?.message ?? "注册失败"
            }
            d.set(u, forKey: "login_user")
            storeLoginToken(t)
            d.set(r.is_admin ?? false, forKey: "login_is_admin")
            d.set(r.vip_level?.value ?? 0, forKey: "login_vip")
            username = u; isAdmin = r.is_admin ?? false; vipLevel = r.vip_level?.value ?? 0
            rememberAccount()
            sessionExpired = false
            accountGeneration += 1
            await fetchMyId()
            if let key = TokenVault.deriveKey(password: p) {
                TokenVault.saveKey(key, for: u)
            }
            await TokenVault.pullTokens(session: self)
            return nil
        } catch {
            return "网络错误: \(error.localizedDescription)"
        }
    }

    func logout() {
        // 完整退出: 服务端作废令牌 + 从已保存账号列表移除 (一键切换里走 signOutLocal 则保留)
        if let u = username {
            savedAccounts.removeAll { $0.username == u }
            persistSavedAccounts()
        }
        let t = loginToken
        if !t.isEmpty {
            Task { let _: [EmptyResp] = (try? await SB.rpc("logout", params: ["p_token": t])) ?? [] }
        }
        d.removeObject(forKey: "login_user")
        SessionKeychain.remove("login_token")
        d.removeObject(forKey: "login_token")
        d.removeObject(forKey: "login_is_admin")
        d.removeObject(forKey: "login_vip")
        d.removeObject(forKey: "sb_token")
        d.removeObject(forKey: "gh_token")
        d.removeObject(forKey: "login_user_id")
        username = nil; isAdmin = false; vipLevel = 0; myUserId = nil
        accountGeneration += 1
    }

    /// 启动时校验本地会话: 身份以服务端为准。
    /// 服务端明确回复有效 → 按服务端刷新管理员/VIP (本地标志被改也会被纠正);
    /// 服务端明确回复无效 → 立即降权 (清管理员/VIP 标志, 防改本地配置冒用站主功能),
    /// 但不清 token 本身 (与网站一致, 避免网络抖动误登出); 网络失败则不动。
    func validateSession() async {
        guard isLoggedIn else { isBanned = false; appealWaitSeconds = 0; return }
        struct R: Decodable { var valid: Bool?; var username: String?; var is_admin: Bool?; var vip_level: FlexInt? }
        guard let rows: [R] = try? await SB.rpc("check_session", params: ["p_token": loginToken]),
              let r = rows.first else { return }
        if r.valid == true {
            sessionExpired = false
            isAdmin = r.is_admin ?? false
            vipLevel = r.vip_level?.value ?? 0
            d.set(isAdmin, forKey: "login_is_admin")
            d.set(vipLevel, forKey: "login_vip")
        } else {
            // 服务端明确说令牌已失效 (不是网络错误 —— 网络错误在上面的 guard 就返回了):
            // 旧版只把管理员标记清零、照样装作登录着, 于是令牌拉不到、生成兑换码没反应、
            // 爬作者报无令牌, 用户还以为是功能坏了。现在明确标记, RootView 弹窗请用户重登。
            sessionExpired = true
            isAdmin = false
            vipLevel = 0
            d.set(false, forKey: "login_is_admin")
            d.set(0, forKey: "login_vip")
        }
        await fetchMyId()
        await fetchBanStatus()
        await DeviceReporter.report()
    }

    /// 封禁状态 (服务端为准): appeal_info 返回是否被封 + 申诉冷却剩余秒数
    func fetchBanStatus() async {
        struct R: Decodable { var banned: Bool?; var wait_seconds: Int? }
        let rows: [R]? = try? await SB.rpc("appeal_info", params: ["p_token": loginToken])
        if let r = rows?.first {
            isBanned = r.banned ?? false
            appealWaitSeconds = r.wait_seconds ?? 0
        }
    }

    /// 拉自己的用户 ID (站主判定只认它): 按用户名查 user_accounts.id (该列已开放读取)
    func fetchMyId() async {
        guard let u = username else { return }
        struct R: Decodable { var id: Int? }
        let (rows, _): ([R], Int?) = (try? await SB.get("rest/v1/user_accounts", query: [
            URLQueryItem(name: "select", value: "id"),
            URLQueryItem(name: "username", value: "eq." + u),
            URLQueryItem(name: "limit", value: "1"),
        ])) ?? ([], nil)
        if let row = rows.first, let id = row.id {
            myUserId = id
            d.set(id, forKey: "login_user_id")
        }
    }
}

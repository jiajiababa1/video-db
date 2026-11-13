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

/// 会话状态: 设备 ID / 门禁 token / 账号登录 (令牌在钥匙串, 其余与网站 localStorage 同构)
final class Session: ObservableObject {
    static let shared = Session()

    @Published var gatePassed: Bool
    @Published var username: String?
    @Published var isAdmin: Bool = false
    @Published var vipLevel: Int = 0

    private let d = UserDefaults.standard

    init() {
        gatePassed = !SessionKeychain.migrated(account: "gate_token", legacyKey: "vid_gate_token", defaults: d).isEmpty
        username = d.string(forKey: "login_user")
        isAdmin = d.bool(forKey: "login_is_admin")
        vipLevel = d.integer(forKey: "login_vip")
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
    /// 站主闸门 (与网站 isOwner 近似: 管理员账号或本机存有 gh_token)
    var isOwner: Bool { isAdmin || ghToken.isEmpty == false }

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
            // 派生云端配置解密密钥并取回跟账号走的令牌 (gh/sb token)
            if let key = TokenVault.deriveKey(password: p) {
                TokenVault.saveKey(key)
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
            if let key = TokenVault.deriveKey(password: p) {
                TokenVault.saveKey(key)
            }
            await TokenVault.pullTokens(session: self)
            return nil
        } catch {
            return "网络错误: \(error.localizedDescription)"
        }
    }

    func logout() {
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
        TokenVault.clearKey()
        username = nil; isAdmin = false; vipLevel = 0
    }

    /// 启动时校验本地会话: 身份以服务端为准。
    /// 服务端明确回复有效 → 按服务端刷新管理员/VIP (本地标志被改也会被纠正);
    /// 服务端明确回复无效 → 立即降权 (清管理员/VIP 标志, 防改本地配置冒用站主功能),
    /// 但不清 token 本身 (与网站一致, 避免网络抖动误登出); 网络失败则不动。
    func validateSession() async {
        guard isLoggedIn else { return }
        struct R: Decodable { var valid: Bool?; var username: String?; var is_admin: Bool?; var vip_level: FlexInt? }
        guard let rows: [R] = try? await SB.rpc("check_session", params: ["p_token": loginToken]),
              let r = rows.first else { return }
        if r.valid == true {
            isAdmin = r.is_admin ?? false
            vipLevel = r.vip_level?.value ?? 0
            d.set(isAdmin, forKey: "login_is_admin")
            d.set(vipLevel, forKey: "login_vip")
        } else {
            isAdmin = false
            vipLevel = 0
            d.set(false, forKey: "login_is_admin")
            d.set(0, forKey: "login_vip")
        }
    }
}

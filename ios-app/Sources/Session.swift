import Foundation
import Combine

/// 会话状态: 设备 ID / 门禁 token / 账号登录 (与网站 localStorage 同构, 存 UserDefaults)
final class Session: ObservableObject {
    static let shared = Session()

    @Published var gatePassed: Bool
    @Published var username: String?
    @Published var isAdmin: Bool = false
    @Published var vipLevel: Int = 0

    private let d = UserDefaults.standard

    init() {
        gatePassed = (d.string(forKey: "vid_gate_token")?.isEmpty == false)
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

    var gateToken: String { d.string(forKey: "vid_gate_token") ?? "" }
    var loginToken: String { d.string(forKey: "login_token") ?? "" }
    var isLoggedIn: Bool { username != nil && !loginToken.isEmpty }
    /// 站主闸门 (与网站 isOwner 近似: 管理员账号或本机存有 gh_token)
    var isOwner: Bool { isAdmin || ghToken.isEmpty == false }

    var ghToken: String {
        get { d.string(forKey: "gh_token") ?? "" }
        set { d.set(newValue, forKey: "gh_token") }
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
            d.set(t, forKey: "vid_gate_token")
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
            d.set(t, forKey: "login_token")
            d.set(r.is_admin ?? false, forKey: "login_is_admin")
            d.set(r.vip_level?.value ?? 0, forKey: "login_vip")
            username = u; isAdmin = r.is_admin ?? false; vipLevel = r.vip_level?.value ?? 0
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
        d.removeObject(forKey: "login_token")
        d.removeObject(forKey: "login_is_admin")
        d.removeObject(forKey: "login_vip")
        username = nil; isAdmin = false; vipLevel = 0
    }

    /// 启动时校验本地会话 (失败不清 token, 与网站一致)
    func validateSession() async {
        guard isLoggedIn else { return }
        struct R: Decodable { var valid: Bool?; var username: String?; var is_admin: Bool?; var vip_level: FlexInt? }
        if let rows: [R] = try? await SB.rpc("check_session", params: ["p_token": loginToken]),
           let r = rows.first, r.valid == true {
            isAdmin = r.is_admin ?? isAdmin
            vipLevel = r.vip_level?.value ?? vipLevel
        }
    }
}

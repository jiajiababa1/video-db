import Foundation
import CommonCrypto
import CryptoKit
import Security

/// 账号令牌保险箱: 与网站 cloud_user_config 完全同构 —
/// gh_token / sb_token 用登录密码派生密钥 (PBKDF2-SHA256 15万次) AES-GCM 加密后跟账号存云端,
/// 登录即自动解密取回, 换设备也不用再找 token。
enum TokenVault {

    // MARK: - 密钥派生 (与网站 deriveEncKey 逐项一致)
    static func deriveKey(password: String) -> Data? {
        let mat = Data(("gb-token-enc:v1:" + password).utf8)
        let salt = Data("gb-token-enc-salt-v1".utf8)
        var key = Data(count: 32)
        let status: Int32 = key.withUnsafeMutableBytes { keyBuf in
            mat.withUnsafeBytes { matBuf in
                salt.withUnsafeBytes { saltBuf in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        matBuf.baseAddress!.assumingMemoryBound(to: CChar.self), mat.count,
                        saltBuf.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 150_000,
                        keyBuf.baseAddress!.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        return status == 0 ? key : nil
    }

    // MARK: - 派生密钥存 iOS 钥匙串 (对应网站的 localStorage gb_enc_key)
    private static var kcQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "vdb.enc",
         kSecAttrAccount as String: "gb_enc_key"]
    }

    static func saveKey(_ data: Data) {
        SecItemDelete(kcQuery as CFDictionary)
        var q = kcQuery
        q[kSecValueData as String] = data
        SecItemAdd(q as CFDictionary, nil)
    }

    static func loadKey() -> Data? {
        var q = kcQuery
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func clearKey() {
        SecItemDelete(kcQuery as CFDictionary)
    }

    // MARK: - AES-GCM 令牌加解密 (密文格式 enc:v1:<iv b64url>:<ct+tag b64url>, 与网站一致)
    static func encrypt(key: Data, plain: String) -> String? {
        let sym = SymmetricKey(data: key)
        let nonce = AES.GCM.Nonce()
        guard let box = try? AES.GCM.seal(Data(plain.utf8), using: sym, nonce: nonce) else { return nil }
        let ctWithTag = box.ciphertext + box.tag
        return "enc:v1:" + b64u(Data(box.nonce)) + ":" + b64u(ctWithTag)
    }

    static func decrypt(key: Data, blob: String) -> String? {
        guard blob.hasPrefix("enc:v1:") else { return blob }  // 非加密值直接用 (与网站一致)
        let parts = blob.split(separator: ":")
        guard parts.count == 4,
              let iv = b64uDecode(String(parts[2])),
              let ctFull = b64uDecode(String(parts[3])), ctFull.count > 16 else { return nil }
        let tag = ctFull.suffix(16)
        let ct = ctFull.prefix(ctFull.count - 16)
        let sym = SymmetricKey(data: key)
        guard let nonce = try? AES.GCM.Nonce(data: iv),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(ct), tag: Data(tag)),
              let pt = try? AES.GCM.open(box, using: sym) else { return nil }
        return String(data: pt, encoding: .utf8)
    }

    static func b64u(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func b64uDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    // MARK: - 云端同步 (cloud_user_config)
    private static func fetchConfigData(user: String) async -> [String: Any]? {
        let urlStr = SB.base.absoluteString + "/rest/v1/cloud_user_config?username=eq."
            + (user.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? user)
            + "&select=data&limit=1"
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        for (k, v) in SB.headers() { req.setValue(v, forHTTPHeaderField: k) }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = rows.first else { return nil }
        return first["data"] as? [String: Any]
    }

    /// 登录后调用: 从云端取回并解密 gh/sb 令牌
    static func pullTokens(session: Session) async {
        guard session.isLoggedIn, let user = session.username,
              let key = loadKey() else { return }
        guard let data = await fetchConfigData(user: user) else { return }
        if let gh = data["ghToken"] as? String, !gh.isEmpty,
           let plain = decrypt(key: key, blob: gh), !plain.isEmpty {
            await MainActor.run { session.ghToken = plain }
        }
        if let sb = data["sbToken"] as? String,
           let plain = decrypt(key: key, blob: sb) {
            await MainActor.run { session.sbToken = plain }
        }
    }

    /// 令牌变更后调用: 加密合并回云端 (保留配置里的其他字段)
    static func pushTokens(session: Session) async {
        guard session.isLoggedIn, let user = session.username,
              let key = loadKey() else { return }
        var data = await fetchConfigData(user: user) ?? [:]
        data["ghToken"] = session.ghToken.isEmpty ? "" : (encrypt(key: key, plain: session.ghToken) ?? "")
        data["sbToken"] = session.sbToken.isEmpty ? "" : (encrypt(key: key, plain: session.sbToken) ?? "")
        let body: [String: Any] = [
            "username": user,
            "data": data,
            "updated_at": ISO8601DateFormatter().string(from: Date()),
        ]
        try? await SB.insert("rest/v1/cloud_user_config", body: body,
                             prefer: "resolution=merge-duplicates,return=minimal")
    }
}

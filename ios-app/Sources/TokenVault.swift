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
    // v4.8 起按账号分槽: 旧版全机共用一把密钥, 切号时还会被 clearKey 删掉,
    // 切回站主号 (免密切换, 没法重新派生) 就永远解不开云端令牌 —— 用户实测的「切号挤掉令牌」。
    // 现在每个账号一把自己的密钥, 切号/退出都不删任何账号的密钥。
    private static func kcQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "vdb.enc",
         kSecAttrAccount as String: account]
    }

    static func saveKey(_ data: Data, for user: String) {
        let q0 = kcQuery(account: "gb_enc_key_" + user)
        SecItemDelete(q0 as CFDictionary)
        var q = q0
        q[kSecValueData as String] = data
        SecItemAdd(q as CFDictionary, nil)
    }

    static func loadKey(for user: String) -> Data? {
        var q = kcQuery(account: "gb_enc_key_" + user)
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    /// 旧版共享槽位 (只读, 用于迁移): 能解开某账号的云端令牌就迁进那个账号自己的槽位
    static func loadLegacyKey() -> Data? {
        var q = kcQuery(account: "gb_enc_key")
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
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

    /// 登录后调用: 从云端取回并解密 gh/sb 令牌。
    /// 失败不清空: 取不到配置 / 没有密钥 / 网络抖动 / 解不开时, 一律保留本机现有令牌 ——
    /// 上一版「一失败就清空」把站主在新版里反复清成「无令牌」, 是本次修复的根源。
    /// 防串号靠切号/退出时清 (Session 的 switch/logout 路径已经在做), 不靠这里。
    /// 只有云端明确存了空值才置空; 字段缺失或解不开就完全不动。
    static func pullTokens(session: Session) async {
        guard session.isLoggedIn, let user = session.username else { return }
        guard let data = await fetchConfigData(user: user) else { return }
        let ghBlob = data["ghToken"] as? String
        let sbBlob = data["sbToken"] as? String
        // 候选密钥: 本账号槽位优先, 其次旧版共享槽位 (切号删密钥时代的残留)
        var candidates: [Data] = []
        if let k = loadKey(for: user) { candidates.append(k) }
        if let k = loadLegacyKey(), !candidates.contains(k) { candidates.append(k) }
        var gh: String? = nil
        var sb: String? = nil
        for key in candidates {
            var used = false
            if let blob = ghBlob {
                if blob.isEmpty { gh = "" }
                else if let p = decrypt(key: key, blob: blob) { gh = p; used = true }
            }
            if let blob = sbBlob {
                if blob.isEmpty { sb = "" }
                else if let p = decrypt(key: key, blob: blob) { sb = p; used = true }
            }
            if used {
                // 这把密钥能解本账号的令牌 → 固定进本账号槽位, 以后切号互不影响
                if loadKey(for: user) != key { saveKey(key, for: user) }
                break
            }
            if gh != nil && sb != nil { break }   // 两边都是云端空值, 已处理完
        }
        await MainActor.run {
            if let gh = gh { session.ghToken = gh }
            if let sb = sb { session.sbToken = sb }
        }
    }

    /// 令牌变更后调用: 加密合并回云端 (保留配置里的其他字段)。
    /// 两道保险: ①本机为空不覆盖云端密文; ②候选密钥解不开云端已有密文时不推送
    /// (防错密钥把好密文冲掉)。推送成功用的密钥固定进本账号槽位。
    static func pushTokens(session: Session, forceKey: Data? = nil) async {
        guard session.isLoggedIn, let user = session.username else { return }
        var data = await fetchConfigData(user: user) ?? [:]
        var candidates: [Data] = []
        if let k = loadKey(for: user) { candidates.append(k) }
        if let k = loadLegacyKey(), !candidates.contains(k) { candidates.append(k) }
        guard !candidates.isEmpty || forceKey != nil else { return }
        let ghBlob = data["ghToken"] as? String ?? ""
        let sbBlob = data["sbToken"] as? String ?? ""
        var key: Data? = nil
        if let fk = forceKey {
            key = fk   // 改密码场景: 强制用新密钥重加密覆盖 (旧密文用旧密钥, 解不开是预期内的)
        } else if ghBlob.isEmpty && sbBlob.isEmpty {
            key = candidates.first
        } else {
            for k in candidates {
                let okGH = ghBlob.isEmpty || decrypt(key: k, blob: ghBlob) != nil
                let okSB = sbBlob.isEmpty || decrypt(key: k, blob: sbBlob) != nil
                if okGH && okSB { key = k; break }
            }
        }
        guard let useKey = key else { return }
        if !session.ghToken.isEmpty, let enc = encrypt(key: useKey, plain: session.ghToken) {
            data["ghToken"] = enc
        }
        if !session.sbToken.isEmpty, let enc = encrypt(key: useKey, plain: session.sbToken) {
            data["sbToken"] = enc
        }
        if loadKey(for: user) != useKey { saveKey(useKey, for: user) }
        let body: [String: Any] = [
            "username": user,
            "data": data,
            "updated_at": ISO8601DateFormatter().string(from: Date()),
        ]
        try? await SB.insert("rest/v1/cloud_user_config", body: body,
                             prefer: "resolution=merge-duplicates,return=minimal")
    }
}

import Foundation
import JavaScriptCore
import Security
import Combine
import UIKit

/// 热更新桥: 拉取签名更新包 (GitHub Pages 上的 updates/bundle.json) → 验签 → 应用配置与 JS 模块。
/// 插件 (LiveContainer tweak) 也写同一目录, 谁先跑谁生效; App 自身也能独立完成全流程。
final class Bridge: ObservableObject {
    static let shared = Bridge()

    // 更新包签名公钥 (ECDSA P-256 公钥点, 私钥离线保管, 不进仓库)
    private static let pubKeyB64 = "BJWnDYF+1uy6JOLPRd/AmshmblNQp/jPAP/ypCJPE0jMkirA9i7pIAKk5gFJq8iBcq2vvvS35i3aDOxB1x5TB/I="
    private static let bundleRemote = "https://jiajiababa1.github.io/video-db/updates/bundle.json"

    @Published var bundleVersion: Int = 0
    @Published var announcement: String? = nil
    @Published var featureBoards = true
    @Published var featureWorks = true
    @Published var shelfOrder: [String] = ["continue", "latest", "hsex", "recs"]
    @Published var extraSections: [AppSection] = []
    @Published var moduleNames: [String] = []
    @Published var pluginVersion: String? = nil
    @Published var statusText: String = "未检查"
    @Published var helloRan = false

    struct Module {
        var name: String
        var version: Int
        var kind: String        // bootstrap / resolver
        var prefix: String?
        var js: String
    }

    /// 热更新管理动作 (v1.4): 签名包下发的 JS, 站长在「我的」里点运行;
    /// 动作可调 rest/rpc/input/confirm/toast (原生把关, 仅站长会话可用)。
    struct ActionItem: Identifiable {
        var id: String
        var title: String
        var desc: String?
        var js: String
    }

    @Published var actions: [ActionItem] = []
    @Published var actionLog: String = ""
    @Published var actionRunning: String? = nil

    private var modules: [Module] = []
    private var store: [String: String] = [:]
    private let jsQueue = DispatchQueue(label: "vdb.bridge.js")
    private let d = UserDefaults.standard

    var enabled: Bool {
        get { !d.bool(forKey: "bridge_disabled") }
        set { d.set(!newValue, forKey: "bridge_disabled") }
    }

    var dir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let u = docs.appendingPathComponent("VDBPlugin")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    // MARK: - 启动
    func bootstrap() {
        loadStore()
        readPluginMarker()
        if enabled {
            loadLocalBundle()
            runBootstrapModules()
            Task { await checkUpdate(manual: false) }
        }
    }

    private func readPluginMarker() {
        let f = dir.appendingPathComponent("plugin.json")
        if let data = try? Data(contentsOf: f),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            pluginVersion = obj["version"] as? String
        }
    }

    // MARK: - 更新包: 拉取/验签/应用/回滚
    func checkUpdate(manual: Bool) async {
        guard enabled else {
            await MainActor.run { self.statusText = "远程更新已关闭" }
            return
        }
        let url = URL(string: Bridge.bundleRemote + "?t=" + String(Int(Date().timeIntervalSince1970)))!
        guard let (data, _) = try? await URLSession.shared.data(from: url) else {
            if manual { await MainActor.run { self.statusText = "检查失败: 网络错误" } }
            return
        }
        guard let payloadData = Bridge.verifyAndExtract(data) else {
            await MainActor.run { self.statusText = "更新包验签失败, 已忽略" }
            return
        }
        guard let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let version = payload["version"] as? Int else {
            await MainActor.run { self.statusText = "更新包格式不对, 已忽略" }
            return
        }
        let isNewer = version > bundleVersion
        if isNewer {
            // 存盘 (旧版留作回滚)
            let cur = dir.appendingPathComponent("bundle.json")
            let prev = dir.appendingPathComponent("bundle.prev.json")
            if FileManager.default.fileExists(atPath: cur.path) {
                try? FileManager.default.removeItem(at: prev)
                try? FileManager.default.copyItem(at: cur, to: prev)
            }
            try? data.write(to: cur, options: .atomic)
            apply(payload: payload)
            runBootstrapModules()
            await MainActor.run { self.statusText = "已更新到 v\(version)" }
        } else if manual {
            await MainActor.run { self.statusText = "已是最新 (v\(self.bundleVersion))" }
        }
    }

    func rollback() {
        let cur = dir.appendingPathComponent("bundle.json")
        let prev = dir.appendingPathComponent("bundle.prev.json")
        guard let data = try? Data(contentsOf: prev),
              let payloadData = Bridge.verifyAndExtract(data),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            statusText = "没有可回滚的版本"
            return
        }
        try? FileManager.default.removeItem(at: cur)
        try? FileManager.default.copyItem(at: prev, to: cur)
        apply(payload: payload)
        statusText = "已回滚到 v\(bundleVersion)"
    }

    private func loadLocalBundle() {
        let cur = dir.appendingPathComponent("bundle.json")
        guard let data = try? Data(contentsOf: cur),
              let payloadData = Bridge.verifyAndExtract(data),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { return }
        apply(payload: payload)
    }

    /// 验签并提取 payload (签名对象 = payload_b64 字符串的 UTF-8 字节)
    static func verifyAndExtract(_ bundleData: Data) -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: bundleData) as? [String: Any],
              let payloadB64 = obj["payload_b64"] as? String,
              let sigB64 = obj["sig_b64"] as? String,
              let payloadData = Data(base64Encoded: payloadB64),
              let sig = Data(base64Encoded: sigB64),
              let msg = payloadB64.data(using: .utf8),
              let pubData = Data(base64Encoded: pubKeyB64) else { return nil }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 256,
        ]
        guard let key = SecKeyCreateWithData(pubData as CFData, attrs as CFDictionary, nil) else { return nil }
        guard SecKeyVerifySignature(key, .ecdsaSignatureMessageX962SHA256,
                                     msg as CFData, sig as CFData, nil) else { return nil }
        return payloadData
    }

    private func apply(payload: [String: Any]) {
        let version = payload["version"] as? Int ?? 0
        let config = payload["config"] as? [String: Any] ?? [:]
        var mods: [Module] = []
        if let arr = payload["modules"] as? [[String: Any]] {
            for m in arr {
                guard let name = m["name"] as? String, let js = m["js"] as? String else { continue }
                mods.append(Module(name: name,
                                   version: m["version"] as? Int ?? 1,
                                   kind: m["kind"] as? String ?? "",
                                   prefix: m["prefix"] as? String,
                                   js: js))
            }
        }
        var acts: [ActionItem] = []
        if let arr = payload["actions"] as? [[String: Any]] {
            for a in arr {
                guard let id = a["id"] as? String, let title = a["title"] as? String,
                      let js = a["js"] as? String else { continue }
                acts.append(ActionItem(id: id, title: title, desc: a["desc"] as? String, js: js))
            }
        }
        DispatchQueue.main.async {
            self.bundleVersion = version
            self.announcement = config["announcement"] as? String
            if let flags = config["featureFlags"] as? [String: Any] {
                self.featureBoards = flags["boards"] as? Bool ?? true
                self.featureWorks = flags["works"] as? Bool ?? true
            }
            if let order = config["shelfOrder"] as? [String], !order.isEmpty {
                self.shelfOrder = order
            }
            if let extras = config["extraSections"] as? [[String: Any]] {
                self.extraSections = extras.compactMap { e in
                    guard let id = e["id"] as? String, let name = e["name"] as? String else { return nil }
                    return AppSection(id: id, name: name,
                                      subtitle: e["subtitle"] as? String ?? "", isSource: true)
                }
            }
            self.modules = mods
            self.moduleNames = mods.map { "\($0.name) v\($0.version)" }
            self.actions = acts
        }
    }

    // MARK: - JS 引擎 (JavaScriptCore, 白名单桥)
    private func loadStore() {
        let f = dir.appendingPathComponent("store.json")
        if let data = try? Data(contentsOf: f),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            store = obj
        }
        helloRan = store["hello_ran"] != nil
    }

    private func saveStore() {
        let f = dir.appendingPathComponent("store.json")
        if let data = try? JSONSerialization.data(withJSONObject: store) {
            try? data.write(to: f, options: .atomic)
        }
        let ran = store["hello_ran"] != nil
        DispatchQueue.main.async { self.helloRan = ran }
    }

    /// 在独立 JSContext 里跑一段模块代码, 返回指定全局函数的调用结果
    private func evalJS(_ js: String, video: [String: Any]? = nil, callResolver: Bool = false) -> String? {
        return jsQueue.sync {
            guard let ctx = JSContext() else { return nil }
            var jsError: String? = nil
            ctx.exceptionHandler = { _, exc in jsError = exc?.toString() }
            let bridge = JSBridge(fetch: { [weak self] url in self?.syncFetch(url) },
                                  storeGet: { [weak self] k in self?.store[k] },
                                  storeSet: { [weak self] k, v in
                                      self?.store[k] = v
                                      self?.saveStore()
                                  })
            ctx.setObject(bridge, forKeyedSubscript: "vdb" as NSString)
            ctx.evaluateScript(js)
            if jsError != nil { return nil }
            guard callResolver, let video = video else { return nil }
            ctx.setObject(video, forKeyedSubscript: "video" as NSString)
            let result = ctx.evaluateScript("typeof resolve === 'function' ? resolve(video) : null")
            if jsError != nil { return nil }
            if let s = result?.toString(), s != "null", s != "undefined", !s.isEmpty { return s }
            return nil
        }
    }

    private func syncFetch(_ urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var out: String? = nil
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data = data { out = String(data: data, encoding: .utf8) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 16)
        return out
    }

    func runBootstrapModules() {
        for m in modules where m.kind == "bootstrap" {
            _ = evalJS(m.js)
        }
    }

    /// 解析型模块: 命中 video_id 前缀的模块先试 (返回直链字符串)
    func resolveWithModules(_ v: VideoItem) -> URL? {
        guard enabled else { return nil }
        let videoDict: [String: Any] = [
            "video_id": v.video_id,
            "video_url": v.video_url ?? "",
            "monsnode_video_id": v.monsnode_video_id ?? "",
            "duration": v.duration ?? "",
            "author": v.author ?? "",
            "title": v.title ?? "",
        ]
        for m in modules where m.kind == "resolver" {
            if let p = m.prefix, !p.isEmpty, !v.video_id.hasPrefix(p) { continue }
            if let s = evalJS(m.js, video: videoDict, callResolver: true),
               let url = URL(string: s) {
                return url
            }
        }
        return nil
    }

    // MARK: - 管理动作 (v1.4): 仅站长可运行, JS 经原生桥调数据库
    func runAction(_ a: ActionItem) {
        guard enabled else { actionLog = "远程更新已关闭"; return }
        guard Session.shared.isOwner else { actionLog = "仅站长可运行管理动作"; return }
        guard actionRunning == nil else { return }
        actionRunning = a.id
        actionLog = "▶ 运行「\(a.title)」…"
        let js = a.js
        jsQueue.async { [weak self] in
            guard let self = self else { return }
            var logs: [String] = []
            guard let ctx = JSContext() else {
                DispatchQueue.main.async { self.actionRunning = nil; self.actionLog = "JS 引擎不可用" }
                return
            }
            var jsError: String? = nil
            ctx.exceptionHandler = { _, exc in jsError = exc?.toString() }
            let bridge = AdminJSBridge(
                fetch: { [weak self] url in self?.syncFetch(url) },
                storeGet: { [weak self] k in self?.store[k] },
                storeSet: { [weak self] k, v in self?.store[k] = v; self?.saveStore() },
                rest: { [weak self] m, p, b in self?.syncRest(method: m, path: p, bodyJson: b) },
                rpc: { [weak self] n, p in self?.syncRPC(name: n, paramsJson: p) },
                input: { [weak self] t, ph in self?.promptInput(title: t, placeholder: ph) },
                confirm: { [weak self] t, m in self?.promptConfirm(title: t, message: m) ?? false },
                toast: { msg in logs.append(msg) },
                log: { msg in logs.append(msg) }
            )
            ctx.setObject(bridge, forKeyedSubscript: "vdb" as NSString)
            ctx.evaluateScript(js)
            if jsError == nil {
                ctx.evaluateScript("if (typeof run === 'function') run();")
            }
            let err = jsError
            DispatchQueue.main.async {
                self.actionRunning = nil
                var out = logs.joined(separator: "\n")
                if let err = err { out += (out.isEmpty ? "" : "\n") + "❌ " + err }
                self.actionLog = out.isEmpty ? "已运行 (无输出)" : out
            }
        }
    }

    private func syncRest(method: String, path: String, bodyJson: String?) -> String? {
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: SB.base.absoluteString + "/" + clean) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method.uppercased()
        req.timeoutInterval = 25
        var hdrs = SB.headers()
        if let b = bodyJson, !b.isEmpty {
            req.httpBody = b.data(using: .utf8)
            if req.httpMethod != "GET" { hdrs["Prefer"] = "return=representation" }
        }
        for (k, v) in hdrs { req.setValue(v, forHTTPHeaderField: k) }
        return syncRequest(req)
    }

    private func syncRPC(name: String, paramsJson: String) -> String? {
        guard let url = URL(string: SB.base.absoluteString + "/rest/v1/rpc/" + name) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        for (k, v) in SB.headers() { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = paramsJson.data(using: .utf8)
        return syncRequest(req)
    }

    private func syncRequest(_ req: URLRequest) -> String? {
        let sem = DispatchSemaphore(value: 0)
        var out: String? = nil
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data = data { out = String(data: data, encoding: .utf8) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 26)
        return out
    }

    private static func topVC() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        var vc = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }

    private func promptInput(title: String, placeholder: String) -> String? {
        let sem = DispatchSemaphore(value: 0)
        var result: String? = nil
        DispatchQueue.main.async {
            guard let vc = Bridge.topVC() else { sem.signal(); return }
            let ac = UIAlertController(title: title, message: nil, preferredStyle: .alert)
            ac.addTextField { $0.placeholder = placeholder }
            ac.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in sem.signal() })
            ac.addAction(UIAlertAction(title: "确定", style: .default) { _ in
                result = ac.textFields?.first?.text
                sem.signal()
            })
            vc.present(ac, animated: true)
        }
        _ = sem.wait(timeout: .now() + 180)
        return result
    }

    private func promptConfirm(title: String, message: String) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var result = false
        DispatchQueue.main.async {
            guard let vc = Bridge.topVC() else { sem.signal(); return }
            let ac = UIAlertController(title: title, message: message, preferredStyle: .alert)
            ac.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in sem.signal() })
            ac.addAction(UIAlertAction(title: "确定", style: .default) { _ in
                result = true
                sem.signal()
            })
            vc.present(ac, animated: true)
        }
        _ = sem.wait(timeout: .now() + 180)
        return result
    }
}

/// 暴露给 JS 的白名单桥 (仅 fetchText / log / store)
@objc protocol VDBJSExport: JSExport {
    func fetchText(_ url: String) -> String?
    func log(_ s: String)
    func store(_ k: String, _ v: String)
    func getStore(_ k: String) -> String?
}

final class JSBridge: NSObject, VDBJSExport {
    let fetch: (String) -> String?
    let storeGet: (String) -> String?
    let storeSet: (String, String) -> Void

    init(fetch: @escaping (String) -> String?,
         storeGet: @escaping (String) -> String?,
         storeSet: @escaping (String, String) -> Void) {
        self.fetch = fetch
        self.storeGet = storeGet
        self.storeSet = storeSet
    }

    func fetchText(_ url: String) -> String? { fetch(url) }
    func log(_ s: String) { print("[vdb-module] \(s)") }
    func store(_ k: String, _ v: String) { storeSet(k, v) }
    func getStore(_ k: String) -> String? { storeGet(k) }
}

/// 管理动作用的扩展桥: 在基础白名单之上加 rest / rpc / input / confirm / toast。
/// 只在 runAction (已验站长身份) 时构造, 普通模块拿不到。
@objc protocol VDBAdminJSExport: JSExport {
    func fetchText(_ url: String) -> String?
    func log(_ s: String)
    func toast(_ s: String)
    func store(_ k: String, _ v: String)
    func getStore(_ k: String) -> String?
    func rest(_ method: String, _ path: String, _ bodyJson: String?) -> String?
    func rpc(_ name: String, _ paramsJson: String) -> String?
    func input(_ title: String, _ placeholder: String) -> String?
    func confirm(_ title: String, _ message: String) -> Bool
    func session() -> String
}

final class AdminJSBridge: NSObject, VDBAdminJSExport {
    let fetchFn: (String) -> String?
    let storeGetFn: (String) -> String?
    let storeSetFn: (String, String) -> Void
    let restFn: (String, String, String?) -> String?
    let rpcFn: (String, String) -> String?
    let inputFn: (String, String) -> String?
    let confirmFn: (String, String) -> Bool
    let toastFn: (String) -> Void
    let logFn: (String) -> Void

    init(fetch: @escaping (String) -> String?,
         storeGet: @escaping (String) -> String?,
         storeSet: @escaping (String, String) -> Void,
         rest: @escaping (String, String, String?) -> String?,
         rpc: @escaping (String, String) -> String?,
         input: @escaping (String, String) -> String?,
         confirm: @escaping (String, String) -> Bool,
         toast: @escaping (String) -> Void,
         log: @escaping (String) -> Void) {
        self.fetchFn = fetch
        self.storeGetFn = storeGet
        self.storeSetFn = storeSet
        self.restFn = rest
        self.rpcFn = rpc
        self.inputFn = input
        self.confirmFn = confirm
        self.toastFn = toast
        self.logFn = log
    }

    func fetchText(_ url: String) -> String? { fetchFn(url) }
    func log(_ s: String) { logFn(s) }
    func toast(_ s: String) { toastFn(s) }
    func store(_ k: String, _ v: String) { storeSetFn(k, v) }
    func getStore(_ k: String) -> String? { storeGetFn(k) }
    func rest(_ method: String, _ path: String, _ bodyJson: String?) -> String? { restFn(method, path, bodyJson) }
    func rpc(_ name: String, _ paramsJson: String) -> String? { rpcFn(name, paramsJson) }
    func input(_ title: String, _ placeholder: String) -> String? { inputFn(title, placeholder) }
    func confirm(_ title: String, _ message: String) -> Bool { confirmFn(title, message) }

    func session() -> String {
        let s = Session.shared
        let obj: [String: Any] = ["username": s.username ?? "", "isOwner": s.isOwner]
        if let d = try? JSONSerialization.data(withJSONObject: obj),
           let str = String(data: d, encoding: .utf8) { return str }
        return "{}"
    }
}

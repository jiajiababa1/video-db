import Foundation
import UIKit
import Network

/// 设备信息采集: 登录校验时上报一次 (report_device), 站主在「用户设备信息」页查看。
/// 只采系统开放给普通 App 的设备/系统信息。明确拿不到的:
/// - 电话号码: iOS 不向任何 App 开放读取, 无接口;
/// - 精确位置: 不在采集范围 —— 只有用户主动发送位置消息时才有;
/// - 设备自定义名称: iOS 16 起无权限只返回机型名, 不采。
enum DeviceInfo {
    static func collect() -> [String: Any] {
        var info: [String: Any] = [:]
        info["model"] = modelName()
        info["system_version"] = "iOS " + UIDevice.current.systemVersion
        info["app_version"] = "v4.7"
        info["locale"] = Locale.current.identifier
        info["timezone"] = TimeZone.current.identifier
        let scale = UIScreen.main.scale
        let b = UIScreen.main.bounds
        info["screen"] = "\(Int(b.width * scale))×\(Int(b.height * scale))"
        UIDevice.current.isBatteryMonitoringEnabled = true
        let lvl = UIDevice.current.batteryLevel
        if lvl >= 0 { info["battery"] = Int(lvl * 100) }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let total = attrs[.systemSize] as? Int64,
           let free = attrs[.systemFreeSize] as? Int64 {
            info["storage"] = String(format: "剩余 %.1f GB / 共 %.1f GB", Double(free) / 1e9, Double(total) / 1e9)
        }
        return info
    }

    /// 当前网络类型 (WiFi/蜂窝/无连接), 一次性探测, 最多等 1.5 秒
    static func networkType() async -> String {
        await withCheckedContinuation { cont in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "vdb.netprobe")
            var done = false
            monitor.pathUpdateHandler = { path in
                if done { return }
                done = true
                monitor.cancel()
                if path.usesInterfaceType(.wifi) { cont.resume(returning: "WiFi") }
                else if path.usesInterfaceType(.cellular) { cont.resume(returning: "蜂窝网络") }
                else if path.status == .satisfied { cont.resume(returning: "其他") }
                else { cont.resume(returning: "无连接") }
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1.5) {
                if done { return }
                done = true
                monitor.cancel()
                cont.resume(returning: "未知")
            }
        }
    }

    private static func modelIdentifier() -> String {
        var sys = utsname()
        uname(&sys)
        let mirror = Mirror(reflecting: sys.machine)
        return mirror.children.reduce("") { acc, child in
            guard let v = child.value as? Int8, v != 0 else { return acc }
            return acc + String(UnicodeScalar(UInt8(v)))
        }
    }

    private static func modelName() -> String {
        let id = modelIdentifier()
        let map: [String: String] = [
            "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
            "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,5": "iPhone 16e",
        ]
        if let n = map[id] { return "\(n)（\(id)）" }
        return id
    }
}

/// 上报入口: 已登录时把本机信息发给服务端存档 (失败静默, 不打扰用户)
enum DeviceReporter {
    static func report() async {
        guard Session.shared.isLoggedIn else { return }
        var info = DeviceInfo.collect()
        info["network"] = await DeviceInfo.networkType()
        info["device_id"] = Session.shared.deviceId
        struct R: Decodable { var ok: Bool? }
        let _: [R]? = try? await SB.rpc("report_device", params: [
            "p_token": Session.shared.loginToken, "p_info": info])
    }
}

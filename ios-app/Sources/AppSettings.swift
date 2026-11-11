import Foundation
import Network
import Combine

/// 全局小设置 + 网络状态 (省流量模式用)
enum AppSettings {
    static var dataSaver: Bool {
        get { UserDefaults.standard.bool(forKey: "vdb_data_saver") }
        set { UserDefaults.standard.set(newValue, forKey: "vdb_data_saver") }
    }

    /// 省流量是否真正生效: 开关打开 且 当前走蜂窝网络
    static var saverActive: Bool { dataSaver && NetStatus.shared.isCellular }
}

/// 当前网络类型监听 (只关心是否蜂窝)
final class NetStatus: ObservableObject {
    static let shared = NetStatus()
    @Published var isCellular = false
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let cell = path.usesInterfaceType(.cellular)
            DispatchQueue.main.async { self?.isCellular = cell }
        }
        monitor.start(queue: DispatchQueue(label: "vdb.netstatus"))
    }
}

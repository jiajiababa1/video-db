import Foundation
import UIKit
import SwiftUI

/// 本地错误日志 (#10): 未捕获异常 + 关键路径主动记录, 存 Documents/errlog.txt。
/// 「我的 → 错误日志」可查看 / 复制 / 清空, 出问题截图发开发者即可定位。
enum ErrLog {
    private static let pendingKey = "vdb_pending_crash"
    private static let queue = DispatchQueue(label: "vdb.errlog")

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("errlog.txt")
    }

    private static var stamp: String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    /// App 启动时调用: 装异常处理器 + 把上次崩溃记录转存进日志文件
    static func install() {
        collectPending()
        NSSetUncaughtExceptionHandler { exc in
            let stack = exc.callStackSymbols.prefix(12).joined(separator: "\n")
            let text = "name=\(exc.name.rawValue)\nreason=\(exc.reason ?? "")\n\(stack)"
            UserDefaults.standard.set(text, forKey: ErrLog.pendingKey)
            UserDefaults.standard.synchronize()
        }
    }

    private static func collectPending() {
        if let text = UserDefaults.standard.string(forKey: pendingKey) {
            UserDefaults.standard.removeObject(forKey: pendingKey)
            append("💥 上次运行崩溃:\n" + text)
        }
    }

    static func log(_ tag: String, _ message: String) {
        append("[\(tag)] " + message)
    }

    private static func append(_ line: String) {
        queue.async {
            let entry = "\(stamp) \(line)\n"
            let path = fileURL
            if let handle = try? FileHandle(forWritingTo: path) {
                handle.seekToEndOfFile()
                handle.write(Data(entry.utf8))
                try? handle.close()
            } else {
                try? entry.write(to: path, atomically: true, encoding: .utf8)
            }
            // 超过 256KB 就只保留后半截, 防无限膨胀
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
               let size = attrs[.size] as? NSNumber, size.intValue > 262_144,
               let data = try? Data(contentsOf: path) {
                let tail = data.suffix(131_072)
                try? tail.write(to: path)
            }
        }
    }

    static func readAll() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    static func clear() {
        queue.async { try? FileManager.default.removeItem(at: fileURL) }
    }
}

/// 错误日志查看页
struct ErrLogView: View {
    @State private var text = ""
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            if text.isEmpty {
                Spacer()
                Text("暂无错误记录 🎉").foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .textSelection(.enabled)
                }
            }
            HStack(spacing: 12) {
                Button(copied ? "已复制 ✓" : "复制全部") {
                    UIPasteboard.general.string = text
                    copied = true
                }
                .disabled(text.isEmpty)
                Button("清空", role: .destructive) {
                    ErrLog.clear()
                    text = ""
                }
                .disabled(text.isEmpty)
            }
            .padding(12)
        }
        .navigationTitle("错误日志")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { text = ErrLog.readAll() }
    }
}

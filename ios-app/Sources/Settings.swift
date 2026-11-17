import SwiftUI
import UIKit

// 由 Profile.swift 拆分 (v5.3: 每个功能一个文件, 方便定位问题)

/// 图片缓存 (caches/imgcache) 的大小与清理
enum CacheTool {
    static var imgDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("imgcache")
    }

    static func sizeBytes() -> Int64 {
        guard let files = try? FileManager.default.subpathsOfDirectory(atPath: imgDir.path) else { return 0 }
        var total: Int64 = 0
        for f in files {
            let p = imgDir.appendingPathComponent(f).path
            if let attrs = try? FileManager.default.attributesOfItem(atPath: p),
               let s = attrs[.size] as? Int64 {
                total += s
            }
        }
        return total
    }

    static func sizeText() -> String {
        ByteCountFormatter.string(fromByteCount: sizeBytes(), countStyle: .file)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: imgDir)
        URLCache.shared.removeAllCachedResponses()
    }
}

// MARK: - 个人主页 (抖音式)

struct SettingsView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var bridge: Bridge
    @AppStorage("vdb_autonext") private var autoNext = true
    @State private var saver = AppSettings.dataSaver
    @State private var cacheText = CacheTool.sizeText()

    var body: some View {
        List {
            Section(header: Text("播放")) {
                Toggle("连播自动下一条", isOn: $autoNext)
                Toggle("省流量模式 (蜂窝网络不预加载)", isOn: $saver)
                    .onChange(of: saver) { AppSettings.dataSaver = $0 }
            }
            Section(header: Text("通用")) {
                NavigationLink { AccountSwitcherView() } label: {
                    Label("切换账号", systemImage: "arrow.left.arrow.right")
                }
                NavigationLink { ChangePasswordView() } label: {
                    Label("修改密码", systemImage: "key")
                }
                NavigationLink { DevicesView() } label: {
                    Label("我的设备", systemImage: "iphone")
                }
                NavigationLink { ErrLogView() } label: {
                    Label("错误日志", systemImage: "ladybug")
                }
                HStack {
                    Label("热更新", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Text(bridge.statusText)
                        .font(.caption)
                        .foregroundColor(Theme.sub)
                    Button("检查") { Task { await bridge.checkUpdate(manual: true) } }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Theme.gold2)
                }
                Button {
                    CacheTool.clear()
                    cacheText = CacheTool.sizeText()
                } label: {
                    HStack {
                        Label("清理缓存", systemImage: "trash")
                            .foregroundColor(Theme.text)
                        Spacer()
                        Text(cacheText).foregroundColor(Theme.sub)
                    }
                }
            }
            if session.isAdmin || session.isOwner {
                Section(header: Text("站主功能")) {
                    NavigationLink { AdminView() } label: {
                        Label("站主控制台", systemImage: "crown")
                    }
                    NavigationLink { AuditLogView() } label: {
                        Label("审计日志", systemImage: "list.clipboard")
                    }
                    NavigationLink { LeaderboardView() } label: {
                        Label("作者排行榜", systemImage: "chart.bar")
                    }
                }
            }
            if session.isLoggedIn {
                Section(header: Text("兑换")) {
                    NavigationLink { RedeemView() } label: {
                        Label("兑换 VIP", systemImage: "ticket")
                    }
                }
            }
            Section(header: Text("关于")) {
                HStack {
                    Text("版本")
                    Spacer()
                    Text("v5.4").foregroundColor(Theme.sub)
                }
                if session.isLoggedIn {
                    Button(role: .destructive) { session.logout() } label: {
                        Text("退出登录")
                    }
                }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 创作者中心

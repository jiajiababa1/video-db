import SwiftUI
import UIKit

// 由 Features21.swift 拆分 (v5.2: 每个功能一个文件, 方便定位问题)

struct DanmakuItem: Decodable, Identifiable {
    var id: Int?
    var video_id: String?
    var username: String?
    var content: String?
    var time_offset: Double?
    var created_at: String?
}

/// 弹幕设置 (跟设备走): 字号 / 透明度 / 飘过时长 / 显示区域 / 合并重复。
/// 弹幕条的齿轮按钮打开 DanmakuSettingsView 改这些值, 覆盖层直接读, 立即生效。
enum DanmakuSettings {
    static let fontKey = "vdb_dm_font"        // 11...20, 默认 13
    static let opacityKey = "vdb_dm_opacity"  // 0.3...1, 默认 1
    static let durKey = "vdb_dm_dur"          // 飘过时长秒 5...14, 默认 9 (越小越快)
    static let areaKey = "vdb_dm_area"        // 显示区域 0.35 顶部 / 0.65 半屏 / 1 全屏
    static let mergeKey = "vdb_dm_merge"      // 合并重复弹幕, 默认开
}

struct DanmakuSettingsView: View {
    @AppStorage(DanmakuSettings.fontKey) private var font: Double = 13
    @AppStorage(DanmakuSettings.opacityKey) private var opacity: Double = 1
    @AppStorage(DanmakuSettings.durKey) private var dur: Double = 9
    @AppStorage(DanmakuSettings.areaKey) private var area: Double = 1
    @AppStorage(DanmakuSettings.mergeKey) private var merge: Bool = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("字号") {
                HStack {
                    Slider(value: $font, in: 11...20, step: 1)
                    Text("\(Int(font))").frame(width: 30).foregroundColor(.secondary)
                }
            }
            Section("透明度") {
                HStack {
                    Slider(value: $opacity, in: 0.3...1, step: 0.05)
                    Text("\(Int(opacity * 100))%").frame(width: 44).foregroundColor(.secondary)
                }
            }
            Section("飘过时长 (越短越快)") {
                HStack {
                    Slider(value: $dur, in: 5...14, step: 0.5)
                    Text(String(format: "%.1f 秒", dur)).frame(width: 52).foregroundColor(.secondary)
                }
            }
            Section("显示区域") {
                Picker("显示区域", selection: $area) {
                    Text("顶部").tag(0.35)
                    Text("半屏").tag(0.65)
                    Text("全屏").tag(1.0)
                }
                .pickerStyle(.segmented)
            }
            Section {
                Toggle("合并重复弹幕", isOn: $merge)
            } footer: {
                Text("同一时间刷屏的相同弹幕会合成一条并标出次数，如「前方高能 ×12」。设置只影响显示，立即生效。")
            }
        }
        .navigationTitle("弹幕设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
    }
}

/// 弹幕预处理结果: 合并后的文本 + 出现时间 + 估算宽度 (轨道分配用)
private struct DanmakuPrepared {
    var id: Int
    var base: String
    var count: Int
    var spawn: Double
    var estWidth: CGFloat
    var text: String { count > 1 ? base + " ×\(count)" : base }
}

/// 轨道分配缓存 (引用类型, 避免在 body 里改 @State 值)
private final class DanmakuLaneCache {
    var key: String = ""
    var lanes: [Int: Int] = [:]
}

/// 弹幕层 (v4.9 重做): 轨道分配带碰撞检测 —— 每条弹幕占一条轨道, 按估算宽度算出它
/// 完全进入屏幕的时间, 下一条同轨道弹幕必须等它进完才发, 不再叠成一团
/// (借鉴 B 站开源弹幕引擎 DanmakuFlameMaster 的轨道算法)。
/// 丝滑做法不变: TimelineView 按帧渲染, 以播放器 tick 为锚点按墙钟外推视频时间。
struct DanmakuOverlay: View {
    let items: [DanmakuItem]
    let currentTime: Double
    var playing: Bool = true

    @AppStorage(DanmakuSettings.fontKey) private var fontSize: Double = 13
    @AppStorage(DanmakuSettings.opacityKey) private var dmOpacity: Double = 1
    @AppStorage(DanmakuSettings.durKey) private var duration: Double = 9
    @AppStorage(DanmakuSettings.areaKey) private var area: Double = 1
    @AppStorage(DanmakuSettings.mergeKey) private var merge: Bool = true

    @State private var anchorVideo: Double = 0
    @State private var anchorWall: Date = Date()
    @State private var cache = DanmakuLaneCache()

    private var laneHeight: CGFloat { CGFloat(fontSize) + 9 }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing)) { ctx in
            let vt = videoTime(ctx.date)
            GeometryReader { geo in
                let maxLanes = max(1, Int(geo.size.height * CGFloat(area) / laneHeight))
                let prep = prepared()
                let lanes = lanesFor(prep, width: geo.size.width, maxLanes: maxLanes)
                ZStack(alignment: .topLeading) {
                    ForEach(activePrep(prep, at: vt), id: \.id) { p in
                        Text(p.text)
                            .font(.system(size: CGFloat(fontSize), weight: .semibold))
                            .foregroundColor(.white)
                            .opacity(dmOpacity)
                            .shadow(color: .black.opacity(0.85), radius: 2, x: 0, y: 1)
                            .lineLimit(1)
                            .fixedSize()
                            .offset(x: xPos(p, width: geo.size.width, vt: vt),
                                    y: 4 + CGFloat(lanes[p.id] ?? 0) * laneHeight)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .clipped()
        .onAppear { anchorVideo = currentTime; anchorWall = Date() }
        .onChange(of: currentTime) { t in
            anchorVideo = t
            anchorWall = Date()
        }
        .onChange(of: playing) { _ in
            anchorVideo = currentTime
            anchorWall = Date()
        }
    }

    private func videoTime(_ now: Date) -> Double {
        if !playing { return anchorVideo }
        return anchorVideo + now.timeIntervalSince(anchorWall)
    }

    /// 合并重复: 3 秒内出现的相同弹幕合成一条 (计数), 再按时间排序输出
    private func prepared() -> [DanmakuPrepared] {
        let sorted = items.sorted { ($0.time_offset ?? 0) < ($1.time_offset ?? 0) }
        var out: [DanmakuPrepared] = []
        for d in sorted {
            let t = d.time_offset ?? 0
            let c = (d.content ?? "").trimmingCharacters(in: .whitespaces)
            if c.isEmpty { continue }
            if merge, let last = out.last, last.base == c, t - last.spawn <= 3 {
                out[out.count - 1].count += 1
                continue
            }
            let w = CGFloat(c.count) * CGFloat(fontSize) * 0.98 + 24
            out.append(DanmakuPrepared(id: d.id ?? Int(t * 1000) + out.count,
                                       base: c, count: 1, spawn: t, estWidth: w))
        }
        return out
    }

    /// 轨道分配: 同轨道内, 下一条的出现时间必须 ≥ 上一条「完全进入屏幕」的时间;
    /// 全部轨道都忙时选最早空出的那条 (重叠最小)。结果按输入签名缓存。
    private func lanesFor(_ prep: [DanmakuPrepared], width: CGFloat, maxLanes: Int) -> [Int: Int] {
        let key = "\(prep.count)|\(prep.first?.id ?? 0)|\(prep.last?.id ?? 0)|\(Int(width))|\(maxLanes)|\(fontSize)|\(duration)|\(merge)"
        if cache.key == key { return cache.lanes }
        var freeAt = [Double](repeating: 0, count: max(1, maxLanes))
        var map: [Int: Int] = [:]
        for p in prep {
            let entry = duration * Double(p.estWidth) / Double(max(1, width + p.estWidth))
            var lane = -1
            for i in 0..<freeAt.count where freeAt[i] <= p.spawn { lane = i; break }
            if lane < 0 {
                lane = freeAt.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            }
            map[p.id] = lane
            freeAt[lane] = p.spawn + entry
        }
        cache.key = key
        cache.lanes = map
        return map
    }

    private func activePrep(_ prep: [DanmakuPrepared], at vt: Double) -> [DanmakuPrepared] {
        prep.filter { vt >= $0.spawn && vt - $0.spawn < duration }
    }

    private func xPos(_ p: DanmakuPrepared, width: CGFloat, vt: Double) -> CGFloat {
        let age = vt - p.spawn
        return width - (width + p.estWidth) * CGFloat(age / duration)
    }
}

/// 弹幕发送条 (播放页播放器下方)
struct DanmakuBar: View {
    let videoId: String
    let currentTime: Double
    @Binding var items: [DanmakuItem]
    @Binding var enabled: Bool
    @EnvironmentObject var session: Session
    @State private var draft = ""
    @State private var sending = false
    @State private var showManage = false
    @State private var showSettings = false
    @State private var sendNote: String? = nil

    var body: some View {
        VStack(spacing: 4) {
        HStack(spacing: 8) {
            Button { enabled.toggle() } label: {
                Text("弹")
                    .font(.system(size: 12, weight: .heavy))
                    .frame(width: 30, height: 30)
                    .background(enabled ? Theme.gold : Theme.surface2)
                    .foregroundColor(enabled ? .black : Theme.sub)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            if session.isBanned {
                Text("账号已被封禁，无法发弹幕")
                    .font(.caption).foregroundColor(.red)
                Spacer()
            } else if session.isLoggedIn {
                TextField("发条弹幕…", text: $draft)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .glassCapsule()
                Button("发送") { Task { await send() } }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.gold2)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || sending)
            } else {
                Text("登录后可发弹幕")
                    .font(.caption).foregroundColor(Theme.sub)
                Spacer()
            }
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.sub)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            if !items.isEmpty {
                Button { showManage = true } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.sub)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .sheet(isPresented: $showManage) {
            NavigationView {
                DanmakuListView(items: $items)
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationView {
                DanmakuSettingsView()
            }
        }
        if let sendNote = sendNote {
            Text(sendNote)
                .font(.caption2).foregroundColor(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        struct R: Decodable { var ok: Bool?; var message: String? }
        let rows: [R]? = try? await SB.rpc("send_danmaku", params: [
            "p_token": Session.shared.loginToken, "p_video_id": videoId,
            "p_content": text, "p_offset": currentTime])
        if rows?.first?.ok == true {
            items.append(DanmakuItem(id: -(items.count + 1), video_id: videoId,
                                     username: session.username, content: text,
                                     time_offset: currentTime, created_at: nil))
            items.sort { ($0.time_offset ?? 0) < ($1.time_offset ?? 0) }
            draft = ""
            sendNote = nil
        } else {
            // 旧版失败一声不吭, 用户只看到"点了没反应"。把真实原因显示出来。
            sendNote = rows?.first?.message ?? "发送失败: 登录可能已失效, 退出重新登录一次再试"
        }
        sending = false
    }
}

/// 弹幕管理列表: 本人可删自己的, 管理员/站主可删任何人的 (服务端 delete_danmaku 验权)
struct DanmakuListView: View {
    @Binding var items: [DanmakuItem]
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if items.isEmpty {
                Text("这个视频还没有弹幕")
                    .foregroundColor(.secondary)
            }
            ForEach(items) { d in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.content ?? "")
                            .font(.system(size: 14))
                        Text("\(d.username ?? "?") · \(timeText(d.time_offset ?? 0))")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    if canDelete(d) {
                        Button {
                            Task { await delete(d) }
                        } label: {
                            Image(systemName: "trash").foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = d.content ?? ""
                    } label: {
                        Label("复制弹幕", systemImage: "doc.on.doc")
                    }
                    Button {
                        UIPasteboard.general.string = "\(d.username ?? "") \(d.content ?? "")"
                    } label: {
                        Label("复制作者和弹幕", systemImage: "person.crop.square")
                    }
                }
            }
        }
        .navigationTitle("弹幕管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
    }

    private func canDelete(_ d: DanmakuItem) -> Bool {
        guard session.isLoggedIn else { return false }
        return session.isAdmin || session.isOwner || d.username == session.username
    }

    private func timeText(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func delete(_ d: DanmakuItem) async {
        guard let id = d.id else { return }
        if id < 0 {
            // 本地刚发、还没回库的弹幕: 直接从列表拿掉即可
            items.removeAll { $0.id == id }
            return
        }
        struct R: Decodable { var ok: Bool?; var message: String? }
        let rows: [R]? = try? await SB.rpc("delete_danmaku", params: [
            "p_token": session.loginToken, "p_id": id])
        if rows?.first?.ok == true {
            items.removeAll { $0.id == id }
        }
    }
}

// MARK: - 视频行 (关注流 / 今日新增 / 我赞过的 共用)

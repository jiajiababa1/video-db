import SwiftUI
import UIKit

// 由 Features21.swift 拆分 (v5.2: 每个功能一个文件, 方便定位问题)

final class ProgressSync {
    static let shared = ProgressSync()
    private var pulled = false
    private var lastWrite: [String: Date] = [:]

    struct Row: Decodable { var video_id: String?; var progress: Double? }

    /// 把服务端进度补进本机片库 (只补本机没有的条目, 本机已有以本机为准)
    func pullIntoLibrary(_ library: Library) {
        guard !pulled, Session.shared.isLoggedIn else { return }
        pulled = true
        Task {
            let rows: [Row]? = try? await SB.rpc("get_progress", params: [
                "p_token": Session.shared.loginToken])
            guard let rows = rows, !rows.isEmpty else { return }
            await MainActor.run {
                var changed = false
                for r in rows {
                    if let id = r.video_id, let p = r.progress, library.progress[id] == nil {
                        library.progress[id] = min(max(p, 0), 1)
                        changed = true
                    }
                }
                if changed { library.persistNow() }
            }
        }
    }

    /// 节流上报 (同一视频 8 秒最多一次); 播放 tick 里调用
    func report(videoId: String, frac: Double) {
        guard Session.shared.isLoggedIn, frac > 0.02, frac < 0.98 else { return }
        let now = Date()
        if let last = lastWrite[videoId], now.timeIntervalSince(last) < 8 { return }
        lastWrite[videoId] = now
        Task {
            struct R: Decodable { var ok: Bool? }
            let _: [R]? = try? await SB.rpc("set_progress", params: [
                "p_token": Session.shared.loginToken, "p_video_id": videoId, "p_progress": frac])
        }
    }
}

// MARK: - 弹幕

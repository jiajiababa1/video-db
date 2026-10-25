import Foundation

/// 真实观看计数: 播放成功后给 videos.views +1;
/// 同一账号对同一视频只计一次 (去重标记存本机片库, 随设备走)。
enum ViewCounter {
    static func register(video: VideoItem, user: String?, library: Library) async {
        let key = (user ?? "guest") + "|" + video.video_id
        if library.countedViews.contains(key) { return }
        library.markCounted(key)

        struct VRow: Decodable { var views: FlexInt? }
        let enc = video.video_id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? video.video_id
        let url = SB.base.absoluteString + "/rest/v1/videos?video_id=eq." + enc + "&select=views&limit=1"
        let (rows, _): ([VRow], Int?) = (try? await SB.getRaw(url)) ?? ([], nil)
        guard let cur = rows.first?.views?.value else {
            library.unmarkCounted(key)
            return
        }
        do {
            try await SB.patch("rest/v1/videos", query: [
                URLQueryItem(name: "video_id", value: "eq." + video.video_id),
            ], body: ["views": cur + 1])
            await MainActor.run {
                if var snap = library.snapshots[video.video_id] {
                    snap.views = String(cur + 1)
                    library.snapshots[video.video_id] = snap
                    library.persistNow()
                }
            }
        } catch {
            // 写失败 (如权限) 就撤掉去重标记, 下次播放再试
            library.unmarkCounted(key)
        }
    }
}

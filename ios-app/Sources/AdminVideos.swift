import SwiftUI

// 由 AdminContent.swift 拆分 (v5.3: 每个功能一个文件)

struct AdminVideosView: View {
    @State private var q = ""
    @State private var results: [VideoItem] = []
    @State private var note = ""
    @State private var searching = false
    @State private var editing: VideoItem? = nil

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("搜标题 / 作者", text: $q)
                        .autocorrectionDisabled()
                    Button("搜索") { Task { await search() } }
                        .disabled(q.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                }
                if !note.isEmpty { Text(note).font(.caption).foregroundColor(.secondary) }
            }
            ForEach(results) { v in videoRow(v) }
        }
        .navigationTitle("视频管理")
        .sheet(item: $editing) { v in AdminVideoEditor(video: v) }
    }

    private func videoRow(_ v: VideoItem) -> some View {
        Button { editing = v } label: {
            HStack(spacing: 10) {
                CachedImage(urlString: v.thumbnail_url).frame(width: 64, height: 40).clipped().cornerRadius(4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(v.displayTitle).font(.subheadline).lineLimit(2).foregroundColor(.primary)
                    Text(rowSubtitle(v)).font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func rowSubtitle(_ v: VideoItem) -> String {
        var s = (v.author ?? "?") + " · 观看 " + (v.viewsText ?? "0")
        if v.storedURL == nil && !(v.has_mp4 ?? false) { s += " · 无直链" }
        return s
    }

    private func search() async {
        searching = true
        let page = (try? await FeedService.fetchPage(search: q)) ?? (items: [], total: nil)
        results = page.items
        note = page.items.isEmpty ? "没搜到" : "共 \(page.items.count) 条 (点一条编辑)"
        searching = false
    }
}

struct AdminVideoEditor: View {
    let video: VideoItem
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var author: String
    @State private var thumb: String
    @State private var dur: String
    @State private var views: String
    @State private var note = ""
    @State private var confirmDelete = false

    init(video: VideoItem) {
        self.video = video
        _title = State(initialValue: video.title ?? "")
        _author = State(initialValue: video.author ?? "")
        _thumb = State(initialValue: video.thumbnail_url ?? "")
        _dur = State(initialValue: video.duration ?? "")
        _views = State(initialValue: video.views ?? "0")
    }

    var body: some View {
        NavigationView {
            Form {
                Section("基本信息") {
                    HStack { Text("ID"); Spacer(); Text(video.video_id).font(.caption).foregroundColor(.secondary) }
                    TextField("标题", text: $title)
                    TextField("作者", text: $author)
                    TextField("封面图 URL", text: $thumb).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("时长/直链字段", text: $dur).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("观看数", text: $views).keyboardType(.numberPad)
                }
                Section {
                    Button("保存修改") { Task { await save() } }
                    Button("观看数清零") { views = "0"; Task { await save() } }
                    Button("标记待重爬") { Task { await markRescrape() } }
                }
                Section {
                    Button("删除视频", role: .destructive) { confirmDelete = true }
                }
                if !note.isEmpty { Section { Text(note).font(.callout) } }
            }
            .navigationTitle("编辑视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .confirmationDialog("确定删除该视频？（真删，不进回收站）", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("确认删除", role: .destructive) { Task { await delete() } }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private func patch(_ body: [String: Any]) async -> Bool {
        do {
            try await SB.patch("rest/v1/videos", query: [
                URLQueryItem(name: "video_id", value: "eq." + video.video_id)], body: body)
            return true
        } catch { return false }
    }

    private func save() async {
        let ok = await patch([
            "title": title, "author": author, "thumbnail_url": thumb,
            "duration": dur, "views": Int(views) ?? 0,
            "updated_at": ISO8601DateFormatter().string(from: Date()),
        ])
        note = ok ? "✅ 已保存" : "❌ 保存失败"
    }

    private func markRescrape() async {
        let ok = await patch(["needs_rescrape": true, "updated_at": ISO8601DateFormatter().string(from: Date())])
        note = ok ? "✅ 已标记待重爬" : "❌ 失败"
    }

    private func delete() async {
        let n = await AdminAPI.deleteVideos(ids: [video.video_id])
        note = n > 0 ? "✅ 已删除" : "❌ 删除失败（无权限或不存在）"
        if n > 0 { dismiss() }
    }
}

// MARK: - 公告管理

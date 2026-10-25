import SwiftUI

// MARK: - 视频管理

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
            ForEach(results) { v in
                Button { editing = v } label: {
                    HStack(spacing: 10) {
                        CachedImage(url: v.thumbnail_url).frame(width: 64, height: 40).clipped().cornerRadius(4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.displayTitle).font(.subheadline).lineLimit(2).foregroundColor(.primary)
                            Text("\(v.author ?? "?") · 观看 \(v.viewsText ?? "0")\(v.hasPlayableLink ? "" : " · 无直链")")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("视频管理")
        .sheet(item: $editing) { v in AdminVideoEditor(video: v) }
    }

    private func search() async {
        searching = true
        let page = await FeedService.fetchPage(offset: 0, search: q)
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
        _title = State(initialValue: video.title)
        _author = State(initialValue: video.author ?? "")
        _thumb = State(initialValue: video.thumbnail_url ?? "")
        _dur = State(initialValue: video.duration ?? "")
        _views = State(initialValue: video.views ?? "0")
    }

    var body: some View {
        NavigationStack {
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

struct AdminAnnounceView: View {
    @State private var rows: [[String: Any]] = []
    @State private var title = ""
    @State private var content = ""
    @State private var note = ""

    var body: some View {
        List {
            Section("发布新公告") {
                TextField("标题", text: $title)
                TextField("内容", text: $content)
                Button("发布") { Task { await publish() } }
                    .disabled(title.isEmpty || content.isEmpty)
                if !note.isEmpty { Text(note).font(.caption) }
            }
            Section("全部公告 (\(rows.count))") {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(adminStr(r, "title")).font(.subheadline).bold()
                        Text(adminStr(r, "content")).font(.caption).foregroundColor(.secondary).lineLimit(3)
                        HStack {
                            Text(adminStr(r, "created_at").prefix(10))
                            Text(adminBool(r, "is_active") ? "· 显示中" : "· 已隐藏")
                            Spacer()
                            Button("删除") {
                                if let id = (r["id"] as? NSNumber)?.intValue { Task { await del(id) } }
                            }
                            .font(.caption).foregroundColor(.red)
                        }
                        .font(.caption2).foregroundColor(.secondary)
                    }
                }
                if !rows.isEmpty {
                    Button("清空全部公告", role: .destructive) { Task { await clearAll() } }
                }
            }
        }
        .navigationTitle("公告管理")
        .task { await load() }
    }

    private func load() async {
        rows = await AdminAPI.restRows("rest/v1/announcements", query: [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "100"),
        ])
    }

    private func publish() async {
        let (ok, msg) = await AdminAPI.announcePublish(title: title, content: content)
        note = ok ? "✅ 已发布" : "❌ " + msg
        if ok { title = ""; content = ""; await load() }
    }

    private func del(_ id: Int) async {
        _ = await AdminAPI.announceDelete(id: id)
        await load()
    }

    private func clearAll() async {
        _ = await AdminAPI.announceClear()
        await load()
    }
}

// MARK: - 站内页管理

struct SitePageRow: Identifiable {
    var slug: String
    var title: String
    var content: String
    var id: String { slug }
}

struct AdminPagesView: View {
    @State private var pages: [SitePageRow] = []
    @State private var editing: SitePageRow? = nil
    @State private var creating = false

    var body: some View {
        List {
            ForEach(pages) { p in
                Button { editing = p } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title).foregroundColor(.primary)
                            Text(p.slug).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            Button { creating = true } label: { Label("新建页面", systemImage: "plus") }
        }
        .navigationTitle("站内页管理")
        .task { await load() }
        .sheet(item: $editing) { p in AdminPageEditor(page: p, isNew: false) { Task { await load() } } }
        .sheet(isPresented: $creating) {
            AdminPageEditor(page: SitePageRow(slug: "", title: "", content: ""), isNew: true) { Task { await load() } }
        }
    }

    private func load() async {
        let rows = await AdminAPI.restRows("rest/v1/site_pages", query: [
            URLQueryItem(name: "select", value: "slug,title,content"),
            URLQueryItem(name: "order", value: "slug.asc"),
        ])
        pages = rows.map { SitePageRow(slug: adminStr($0, "slug"), title: adminStr($0, "title"), content: adminStr($0, "content")) }
    }
}

struct AdminPageEditor: View {
    let isNew: Bool
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var slug: String
    @State private var title: String
    @State private var content: String
    @State private var note = ""

    init(page: SitePageRow, isNew: Bool, onDone: @escaping () -> Void) {
        self.isNew = isNew
        self.onDone = onDone
        _slug = State(initialValue: page.slug)
        _title = State(initialValue: page.title)
        _content = State(initialValue: page.content)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("slug（英文标识）", text: $slug)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .disabled(!isNew)
                TextField("标题", text: $title)
                Section("正文（支持简单 HTML）") {
                    TextEditor(text: $content).frame(minHeight: 220)
                }
                Button("保存") { Task { await save() } }
                    .disabled(slug.isEmpty || title.isEmpty)
                if !isNew {
                    Button("删除该页", role: .destructive) { Task { await del() } }
                }
                if !note.isEmpty { Text(note).font(.callout) }
            }
            .navigationTitle(isNew ? "新建页面" : "编辑页面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }

    private func save() async {
        let (ok, msg) = await AdminAPI.sitepageSave(slug: slug, title: title, content: content)
        note = ok ? "✅ 已保存" : "❌ " + msg
        if ok { onDone(); dismiss() }
    }

    private func del() async {
        _ = await AdminAPI.sitepageDelete(slug: slug)
        onDone(); dismiss()
    }
}

// MARK: - 评论管理

struct AdminCommentsView: View {
    @State private var rows: [[String: Any]] = []

    var body: some View {
        List {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("@" + adminStr(r, "username")).font(.subheadline).bold()
                        Text(adminStr(r, "video_id")).font(.caption2).foregroundColor(.secondary)
                        Spacer()
                        Button("删除") {
                            if let id = (r["id"] as? NSNumber)?.intValue { Task { await del(id) } }
                        }
                        .font(.caption).foregroundColor(.red)
                    }
                    Text(adminStr(r, "content")).font(.callout)
                    Text(String(adminStr(r, "created_at").prefix(16))).font(.caption2).foregroundColor(.secondary)
                }
            }
            if rows.isEmpty { Text("暂无评论").foregroundColor(.secondary) }
        }
        .navigationTitle("评论管理")
        .task { await load() }
    }

    private func load() async {
        rows = await AdminAPI.restRows("rest/v1/video_comments", query: [
            URLQueryItem(name: "select", value: "id,video_id,username,content,created_at"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "100"),
        ])
    }

    private func del(_ id: Int) async {
        _ = try? await SB.delete("rest/v1/video_comments", query: [
            URLQueryItem(name: "id", value: "eq.\(id)")])
        await load()
    }
}

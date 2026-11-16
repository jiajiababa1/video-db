import SwiftUI

// 由 AdminContent.swift 拆分 (v5.3: 每个功能一个文件)

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

struct SitePageRow: Identifiable {
    var slug: String
    var title: String
    var content: String
    var id: String { slug }
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

    /// 与网站 saveSitePage 完全一致的路径清洗: 去空格→小写→非法字符转 -→连续 - 合并。
    /// 不清洗的话页面存进库的路径和网站识别的路径对不上, 建完打不开 (识别错误)。
    private var normalizedSlug: String {
        let lowered = slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var out = ""
        var lastDash = false
        for ch in lowered {
            if (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") || ch == "_" {
                out.append(ch)
                lastDash = false
            } else if ch == "-" {
                if !lastDash { out.append(ch) }
                lastDash = true
            } else {
                if !lastDash { out.append("-") }
                lastDash = true
            }
        }
        return out
    }

    private var slugUsable: Bool {
        !isNew || (!normalizedSlug.isEmpty && normalizedSlug != "-")
    }

    var body: some View {
        NavigationView {
            Form {
                TextField("slug（英文标识）", text: $slug)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .disabled(!isNew)
                if isNew && !slug.isEmpty {
                    if slugUsable {
                        if normalizedSlug != slug {
                            Text("网站会按这个路径识别：/" + normalizedSlug)
                                .font(.caption).foregroundColor(Theme.gold2)
                        }
                    } else {
                        Text("⚠️ 这个路径识别不了（中文/符号会被清掉），请换成英文或拼音，如 about、help")
                            .font(.caption).foregroundColor(.orange)
                    }
                }
                TextField("标题", text: $title)
                Section("正文（支持简单 HTML）") {
                    TextEditor(text: $content).frame(minHeight: 220)
                }
                Button("保存") { Task { await save() } }
                    .disabled(slug.isEmpty || title.isEmpty || !slugUsable)
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
        // 新建时传清洗后的路径 (与网站一致); 编辑时 slug 本就是库里的原值
        let finalSlug = isNew ? normalizedSlug : slug
        let (ok, msg) = await AdminAPI.sitepageSave(
            slug: finalSlug,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            content: content.trimmingCharacters(in: .whitespacesAndNewlines))
        note = ok ? "✅ 已保存（路径 /" + finalSlug + "）" : "❌ " + msg
        if ok { onDone(); dismiss() }
    }

    private func del() async {
        _ = await AdminAPI.sitepageDelete(slug: slug)
        onDone(); dismiss()
    }
}

// MARK: - 评论管理

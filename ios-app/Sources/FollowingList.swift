import SwiftUI
import UIKit

// 由 Profile.swift 拆分 (v5.2: 每个功能一个文件, 方便定位问题)

/// 我关注的人 (作者): 数据 = Library.follows (跟账号走), 点任意一位进作者主页。
/// v4.9 加分组: 长按作者可移动分组/取消关注; 右上角建组; 分组头可重命名/删除
/// (删组不取消关注, 组员回到未分组)。关注更新流顶部可按组筛选。
struct FollowingListView: View {
    @EnvironmentObject var library: Library
    @State private var groups = FollowGroups.load()
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    @State private var showRename = false
    @State private var renameTarget = ""
    @State private var renameText = ""

    private func authors(in g: String?) -> [String] {
        library.follows.filter { groups.map[$0] == g }
    }

    var body: some View {
        List {
            if library.follows.isEmpty {
                Text("还没关注任何作者。在视频右侧或作者主页点「关注」，他们就会出现在这里。长按作者可以分组管理。")
                    .font(.callout).foregroundColor(.secondary)
            }
            ForEach(groups.order, id: \.self) { g in
                if !authors(in: g).isEmpty {
                    Section {
                        ForEach(authors(in: g), id: \.self) { name in authorRow(name) }
                    } header: {
                        HStack {
                            Text(g)
                            Spacer()
                            Menu {
                                Button("重命名") { renameTarget = g; renameText = g; showRename = true }
                                Button("删除分组", role: .destructive) { deleteGroup(g) }
                            } label: {
                                Image(systemName: "ellipsis.circle").foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            if !authors(in: nil).isEmpty {
                if groups.order.isEmpty {
                    Section {
                        ForEach(authors(in: nil), id: \.self) { name in authorRow(name) }
                    }
                } else {
                    Section("未分组") {
                        ForEach(authors(in: nil), id: \.self) { name in authorRow(name) }
                    }
                }
            }
        }
        .navigationTitle("我关注的人")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { newGroupName = ""; showNewGroup = true } label: {
                    Image(systemName: "folder.badge.plus")
                }
            }
        }
        .sheet(isPresented: $showNewGroup) {
            NavigationView {
                groupNameForm(title: "新建分组", text: $newGroupName) { addGroup(newGroupName) }
            }
        }
        .sheet(isPresented: $showRename) {
            NavigationView {
                groupNameForm(title: "重命名分组", text: $renameText) { renameGroup(renameTarget, to: renameText) }
            }
        }
        .onAppear { groups = FollowGroups.load() }
    }

    private func authorRow(_ name: String) -> some View {
        NavigationLink { AuthorView(name: name) } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Theme.surface2).frame(width: 40, height: 40)
                    Text(String(name.prefix(1)))
                        .font(.headline).foregroundColor(Theme.gold2)
                }
                Text(name).font(.body.weight(.medium))
            }
            .padding(.vertical, 2)
        }
        .contextMenu {
            if !groups.order.isEmpty {
                Menu("移动到分组") {
                    ForEach(groups.order, id: \.self) { g in
                        Button(g) { move(name, to: g) }
                    }
                }
            }
            if groups.map[name] != nil {
                Button("移出分组") { move(name, to: nil) }
            }
            Button("取消关注", role: .destructive) { library.toggleFollow(name) }
        }
    }

    private func groupNameForm(title: String, text: Binding<String>, onSave: @escaping () -> Void) -> some View {
        Form {
            TextField("分组名", text: text)
            Button("保存") { onSave(); showNewGroup = false; showRename = false }
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func persist() { FollowGroups.save(groups) }

    private func addGroup(_ raw: String) {
        let g = raw.trimmingCharacters(in: .whitespaces)
        guard !g.isEmpty, !groups.order.contains(g) else { return }
        groups.order.append(g)
        persist()
    }

    private func deleteGroup(_ g: String) {
        groups.order.removeAll { $0 == g }
        groups.map = groups.map.filter { $0.value != g }
        persist()
    }

    private func renameGroup(_ old: String, to raw: String) {
        let n = raw.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != old, !groups.order.contains(n),
              let i = groups.order.firstIndex(of: old) else { return }
        groups.order[i] = n
        for k in Array(groups.map.keys) where groups.map[k] == old { groups.map[k] = n }
        persist()
    }

    private func move(_ name: String, to g: String?) {
        if let g = g { groups.map[name] = g } else { groups.map[name] = nil }
        persist()
    }
}

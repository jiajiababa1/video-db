import SwiftUI

/// 敏感词管理 (站主专属): 评论敏感词库, 服务端按英文逗号分隔存储,
/// 评论内容包含任一词 (不分大小写) 即拦截。注: 目前只过滤评论, 私信未接过滤。
struct BadWordsView: View {
    @State private var words: [String] = []
    @State private var newWord = ""
    @State private var note = ""
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                Text("评论里包含下面任何一个词都会被拦截发送，保存后立即生效。目前只过滤评论，私信还没接过滤。")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("敏感词 (\(words.count))") {
                if loaded && words.isEmpty {
                    Text("还没设置敏感词").foregroundColor(.secondary)
                }
                ForEach(words, id: \.self) { w in
                    Text(w)
                }
                .onDelete { idx in
                    words.remove(atOffsets: idx)
                }
                HStack {
                    TextField("新敏感词", text: $newWord)
                        .autocorrectionDisabled()
                    Button("添加") {
                        let w = newWord.trimmingCharacters(in: .whitespaces)
                        if !w.isEmpty && !words.contains(w) {
                            words.append(w)
                        }
                        newWord = ""
                    }
                }
            }
            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Spacer()
                        Text("保存").fontWeight(.semibold)
                        Spacer()
                    }
                }
                if !note.isEmpty {
                    Text(note).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("敏感词管理")
        .task { await load() }
    }

    private func load() async {
        struct R: Decodable { var value: String? }
        let (rows, _): ([R], Int?) = (try? await SB.get("rest/v1/system_config", query: [
            URLQueryItem(name: "select", value: "value"),
            URLQueryItem(name: "key", value: "eq.bad_words_filter"),
            URLQueryItem(name: "limit", value: "1"),
        ])) ?? ([], nil)
        let raw = rows.first?.value ?? ""
        words = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        loaded = true
    }

    private func save() async {
        let ok = await AdminAPI.configSet(key: "bad_words_filter",
                                          value: words.joined(separator: ","))
        note = ok ? "已保存，立即生效" : "保存失败（服务器拒绝）"
    }
}

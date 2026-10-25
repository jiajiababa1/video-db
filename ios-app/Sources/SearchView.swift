import SwiftUI

/// 搜索页 (标题/作者 ilike 回退式, 与网站回退口径一致)
struct SearchView: View {
    @State private var query = ""
    @State private var submitted = ""
    @State private var authors: [String] = []

    private func searchAuthors(_ q: String) async {
        let qq = FeedService.pgSan(q.trimmingCharacters(in: .whitespaces))
        guard !qq.isEmpty else { authors = []; return }
        struct ARow: Decodable { var author: String? }
        let url = SB.base.absoluteString + "/rest/v1/videos?select=author&author=ilike.*"
            + (qq.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? qq)
            + "*&removed=not.is.true&limit=60"
        let (rows, _): ([ARow], Int?) = (try? await SB.getRaw(url)) ?? ([], nil)
        var seen: [String] = []
        for r in rows {
            if let a = r.author, !a.isEmpty, !seen.contains(a) { seen.append(a) }
        }
        authors = Array(seen.prefix(8))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(Theme.sub)
                TextField("搜视频、作者…", text: $query)
                    .submitLabel(.search)
                    .onSubmit {
                        submitted = query
                        Task { await searchAuthors(query) }
                    }
                if !query.isEmpty {
                    Button {
                        query = ""; submitted = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(Theme.sub)
                    }
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(Theme.surface2)
            .cornerRadius(99)
            .padding(16)

            if submitted.isEmpty {
                Text("输入关键词搜全站视频\n支持标题和作者名")
                    .multilineTextAlignment(.center)
                    .foregroundColor(Theme.sub)
                    .padding(.top, 50)
                Spacer()
            } else {
                if !authors.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(authors, id: \.self) { a in
                                NavigationLink {
                                    FeedView(author: a)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "person.circle.fill")
                                        Text("@" + a).lineLimit(1)
                                    }
                                    .font(.system(size: 13))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(Theme.surface2)
                                    .foregroundColor(Theme.text)
                                    .cornerRadius(99)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 4)
                }
                FeedView(search: submitted, navTitle: "搜索: " + submitted)
                    .id(submitted)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
    }
}

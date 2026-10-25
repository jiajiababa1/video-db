import SwiftUI

/// 搜索页 (标题/作者 ilike 回退式, 与网站回退口径一致)
struct SearchView: View {
    @State private var query = ""
    @State private var submitted = ""
    @State private var authors: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(Theme.sub)
                TextField("搜视频、作者…", text: $query)
                    .submitLabel(.search)
                    .onSubmit { submitted = query }
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
                FeedView(search: submitted, navTitle: "搜索: " + submitted)
                    .id(submitted)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
    }
}

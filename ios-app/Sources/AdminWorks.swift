import SwiftUI

/// 作品审核 (站主专属): 用户投稿先审后发, 通过才进作品墙
struct AdminWorksView: View {
    @State private var works: [SocialAPI.WorkRequest] = []
    @State private var note = ""

    var body: some View {
        List {
            if !note.isEmpty {
                Text(note).font(.caption).foregroundColor(.secondary)
            }
            if works.isEmpty {
                Text("没有待审作品").foregroundColor(.secondary)
            }
            ForEach(works) { w in
                VStack(alignment: .leading, spacing: 5) {
                    Text(w.title ?? "(无标题)")
                        .font(.system(size: 14, weight: .semibold))
                    Text("投稿：@\(w.submitter ?? "") · \(String((w.created_at ?? "").prefix(16)))")
                        .font(.caption2).foregroundColor(.secondary)
                    if let d = w.description, !d.isEmpty {
                        Text(d).font(.caption).foregroundColor(.secondary).lineLimit(3)
                    }
                    HStack(spacing: 10) {
                        Button("通过") {
                            Task {
                                await SocialAPI.approveWork(w)
                                note = "已通过《\(w.title ?? "")》"
                                await load()
                            }
                        }
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Theme.goldGradient).foregroundColor(.black)
                        .cornerRadius(99)
                        Button("驳回") {
                            Task {
                                await SocialAPI.rejectWork(id: w.id)
                                note = "已驳回"
                                await load()
                            }
                        }
                        .font(.system(size: 13)).foregroundColor(.red)
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .navigationTitle("作品审核")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        works = await SocialAPI.pendingWorks()
    }
}

import SwiftUI

/// 栏目页: 全部栏目磁贴 (带实时计数)
struct SectionsView: View {
    @EnvironmentObject var bridge: Bridge
    @State private var counts: [String: Int] = [:]

    private var sections: [AppSection] { FeedService.allSections + bridge.extraSections }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(sections) { sec in
                    NavigationLink {
                        FeedView(section: sec)
                    } label: {
                        tile(sec)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("全部栏目")
        .task { await loadCounts() }
    }

    private func tile(_ sec: AppSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer()
            Text(sec.name)
                .font(.system(size: 16, weight: .bold))
            Text(counts[sec.id].map { "\($0) 条 · " + sec.subtitle } ?? sec.subtitle)
                .font(.caption)
                .foregroundColor(Theme.text.opacity(0.75))
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .padding(14)
        .background(
            LinearGradient(colors: [Theme.surface2, Theme.surface],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .cornerRadius(Theme.cardRadius)
    }

    private func loadCounts() async {
        for sec in sections where !sec.id.isEmpty {
            if let c = await FeedService.count(section: sec) {
                counts[sec.id] = c
            }
        }
    }
}

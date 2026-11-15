import SwiftUI
import UIKit

// 由 Profile.swift 拆分 (v5.2: 每个功能一个文件, 方便定位问题)

struct CreatorCenterView: View {
    @EnvironmentObject var session: Session
    @State private var myWorks: [WorkItem] = []
    @State private var likeCount = 0
    @State private var playItem: VideoItem? = nil

    var body: some View {
        List {
            Section(header: Text("数据")) {
                HStack {
                    Text("发布作品")
                    Spacer()
                    Text("\(myWorks.count)").foregroundColor(Theme.sub)
                }
                HStack {
                    Text("累计获赞")
                    Spacer()
                    Text("\(likeCount)").foregroundColor(Theme.sub)
                }
            }
            Section(header: Text("我的作品")) {
                if myWorks.isEmpty {
                    Text("还没有发布过作品").foregroundColor(Theme.sub)
                }
                ForEach(myWorks) { w in
                    Button { playItem = w.asVideoItem } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(w.title ?? "无标题")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Theme.text)
                                .lineLimit(1)
                            Text(String((w.created_at ?? "").prefix(10)))
                                .font(.caption2).foregroundColor(Theme.sub)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                NavigationLink { WorkSubmitView() } label: {
                    Label("发布新作品", systemImage: "plus.circle")
                }
                NavigationLink { WorksView() } label: {
                    Label("作品广场", systemImage: "square.grid.2x2")
                }
            }
        }
        .navigationTitle("创作者中心")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let me = session.username ?? ""
            let all = await SocialAPI.works()
            myWorks = all.filter { $0.author == me }
            likeCount = await ProfileAPI.receivedLikes()
        }
        .sheet(item: $playItem) { v in
            NavigationView { PlayerView(video: v) }
        }
    }
}

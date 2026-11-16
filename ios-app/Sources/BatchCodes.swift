import SwiftUI
import UIKit

/// 批量兑换码 (站主专属): 一次生成多个, 一键复制全部
struct BatchCodesView: View {
    @State private var level = "gold"
    @State private var count = 5
    @State private var uses = 1
    @State private var minutes = 43200
    @State private var perm = false
    @State private var codes: [String] = []
    @State private var busy = false
    @State private var note = ""

    var body: some View {
        List {
            Section("批量生成") {
                Picker("等级", selection: $level) {
                    ForEach(["vip", "svip", "bronze", "silver", "gold", "platinum"], id: \.self) {
                        Text($0).tag($0)
                    }
                }
                Stepper("生成数量：\(count)", value: $count, in: 1...20)
                Stepper("每个可用次数：\(uses)", value: $uses, in: 1...100)
                Picker("时长", selection: $minutes) {
                    Text("1 天").tag(1440)
                    Text("7 天").tag(10080)
                    Text("30 天").tag(43200)
                }
                .disabled(perm)
                Toggle("永久", isOn: $perm)
                Button {
                    Task { await gen() }
                } label: {
                    HStack {
                        Spacer()
                        Text(busy ? "生成中…" : "批量生成 \(count) 个")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(busy)
                if !note.isEmpty {
                    Text(note).font(.caption).foregroundColor(.secondary)
                }
            }
            if !codes.isEmpty {
                Section("本次生成 (\(codes.count))") {
                    ForEach(codes, id: \.self) { c in
                        Text(c).font(.system(.subheadline, design: .monospaced))
                    }
                    Button {
                        UIPasteboard.general.string = codes.joined(separator: "\n")
                        note = "已复制全部 \(codes.count) 个兑换码"
                    } label: {
                        Label("复制全部", systemImage: "doc.on.doc")
                    }
                }
            }
        }
        .navigationTitle("批量兑换码")
    }

    private func gen() async {
        busy = true
        var got: [String] = []
        var lastMsg: String? = nil
        for _ in 0..<count {
            let r = await AdminAPI.generateCode(level: level, uses: uses,
                                                minutes: minutes, permanent: perm)
            if let c = r.code { got.append(c) } else { lastMsg = r.message }
        }
        codes = got
        note = got.isEmpty
            ? ("生成失败：" + (lastMsg ?? "未知原因"))
            : "成功生成 \(got.count)/\(count) 个"
        busy = false
    }
}

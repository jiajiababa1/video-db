import SwiftUI
import UIKit

// 由 AdminOps.swift 拆分 (v5.2: 每个功能一个文件, 方便定位问题)

struct AdminCodesView: View {
    @State private var codes: [AdminAPI.CodeRow] = []
    @State private var level = "vip"
    @State private var uses = 1
    @State private var minutes = 43200
    @State private var perm = false
    @State private var note = ""
    @State private var confirmDeleteCode = false
    @State private var pendingDelete = ""

    var body: some View {
        List {
            Section("生成兑换码") {
                Picker("等级", selection: $level) {
                    ForEach(["vip", "svip", "bronze", "silver", "gold", "platinum"], id: \.self) { Text($0).tag($0) }
                }
                Stepper("可用次数：\(uses)", value: $uses, in: 1...100)
                Picker("时长", selection: $minutes) {
                    Text("1 天").tag(1440); Text("7 天").tag(10080); Text("30 天").tag(43200)
                }
                .disabled(perm)
                Toggle("永久", isOn: $perm)
                Button("生成") { Task { await gen() } }
                if !note.isEmpty { Text(note).font(.callout) }
            }
            Section("已有兑换码 (\(codes.count))") {
                ForEach(codes) { c in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(c.code ?? "?").font(.system(.subheadline, design: .monospaced))
                            Spacer()
                            Text((c.level ?? "") + " · 用 \(c.used_count?.value ?? 0)/\(c.uses?.value ?? 0)")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        HStack(spacing: 18) {
                            Button {
                                UIPasteboard.general.string = c.code ?? ""
                                note = "已复制：" + (c.code ?? "")
                            } label: {
                                Label("复制", systemImage: "doc.on.doc")
                                    .font(.caption.weight(.bold))
                            }
                            .buttonStyle(.plain)
                            Button(role: .destructive) {
                                pendingDelete = c.code ?? ""
                                confirmDeleteCode = true
                            } label: {
                                Label("删除", systemImage: "trash")
                                    .font(.caption.weight(.bold))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("兑换码")
        .task { codes = await AdminAPI.listCodes() }
        .confirmationDialog("删除兑换码 \(pendingDelete)？", isPresented: $confirmDeleteCode, titleVisibility: .visible) {
            Button("确认删除", role: .destructive) { Task { await deleteCode() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后这个码立即作废，还没兑换的人将无法再用。")
        }
    }

    private func deleteCode() async {
        struct R: Decodable { var ok: Bool?; var message: String? }
        let rows: [R]? = try? await SB.rpc("admin_delete_code", params: [
            "p_token": Session.shared.loginToken, "p_code": pendingDelete])
        note = rows?.first?.ok == true ? "已删除：" + pendingDelete : (rows?.first?.message ?? "删除失败")
        codes = await AdminAPI.listCodes()
    }

    private func gen() async {
        let r = await AdminAPI.generateCode(level: level, uses: uses, minutes: minutes, permanent: perm)
        if let code = r.code, !code.isEmpty {
            note = "✅ 新码：" + code
        } else {
            note = "生成失败：" + (r.message ?? "未知原因")
        }
        codes = await AdminAPI.listCodes()
    }
}

// MARK: - 令牌配置 (站主的 GitHub / Supabase 令牌; 入口曾随旧「我的」页一起丢失, 这里补回)

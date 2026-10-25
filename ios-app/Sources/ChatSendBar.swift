import SwiftUI
import Foundation
import UniformTypeIdentifiers

// MARK: - 聊天输入条 (文字 + 表情/语音/位置/照片/视频/文件, 单聊与群聊共用)
struct ChatSendBar: View {
    var enabled: Bool = true
    var onSend: (MsgContent) -> Void
    @State private var text = ""
    @State private var showStickers = false
    @State private var showPicker = false
    @State private var showFiles = false
    @State private var busy = false
    @State private var note: String? = nil
    @StateObject private var recorder = VoiceRecorder()
    private let locator = LocationFetcher()

    var body: some View {
        VStack(spacing: 8) {
            if let note = note {
                Text(note).font(.caption).foregroundColor(Theme.sub)
            }
            if showStickers {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 10) {
                    ForEach(MsgContent.stickers, id: \.self) { e in
                        Button {
                            onSend(.sticker(e))
                            showStickers = false
                        } label: {
                            Text(e).font(.system(size: 26))
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            if recorder.recording {
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill").foregroundColor(.red)
                    Text("录音中 \(recorder.seconds)s")
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    Button("停止并发送") { stopAndSendVoice() }
                        .font(.system(size: 13, weight: .bold)).foregroundColor(Theme.gold2)
                    Button("取消") { _ = recorder.stop() }
                        .font(.system(size: 13)).foregroundColor(Theme.sub)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.surface2).cornerRadius(12)
            }
            HStack(spacing: 8) {
                Menu {
                    Button { showPicker = true } label: { Label("照片 / 视频", systemImage: "photo") }
                    Button { showFiles = true } label: { Label("文件", systemImage: "doc") }
                    Button { Task { await sendLocation() } } label: { Label("位置", systemImage: "location") }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 24)).foregroundColor(Theme.gold2)
                }
                .disabled(!enabled || busy)
                Button { showStickers.toggle() } label: {
                    Text("😀").font(.system(size: 20))
                }
                .disabled(!enabled || busy)
                Button { recorder.start() } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 17)).foregroundColor(Theme.gold2)
                }
                .disabled(!enabled || busy || recorder.recording)
                TextField("发消息…", text: $text)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Theme.surface2).cornerRadius(99)
                    .disabled(!enabled)
                Button("发送") {
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty {
                        onSend(.text(t))
                        text = ""
                    }
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Theme.gold2)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || !enabled)
                if busy { ProgressView().tint(Theme.gold) }
            }
        }
        .padding(12)
        .sheet(isPresented: $showPicker) {
            MediaPicker { url, isVideo in
                Task { await uploadPicked(url: url, isVideo: isVideo) }
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let u = urls.first {
                Task { await uploadFile(u) }
            }
        }
    }

    private func uploadPicked(url: URL, isVideo: Bool) async {
        busy = true
        note = "上传中…"
        let link = await Uploader.upload(fileURL: url, mime: isVideo ? "video/mp4" : "image/jpeg")
        busy = false
        note = link == nil ? "上传失败, 换个小一点的文件试试" : nil
        if let link = link { onSend(isVideo ? .video(link) : .img(link)) }
    }

    private func uploadFile(_ u: URL) async {
        busy = true
        note = "上传中…"
        let scoped = u.startAccessingSecurityScopedResource()
        let data = try? Data(contentsOf: u)
        if scoped { u.stopAccessingSecurityScopedResource() }
        var link: String? = nil
        if let data = data {
            link = await Uploader.upload(data: data, filename: u.lastPathComponent,
                                         mime: "application/octet-stream")
        }
        busy = false
        note = link == nil ? "上传失败" : nil
        if let link = link, let data = data {
            onSend(.file(url: link, name: u.lastPathComponent, size: data.count))
        }
    }

    private func sendLocation() async {
        note = "定位中…"
        if let loc = await locator.fetch() {
            note = nil
            onSend(.loc(name: "我的位置", lat: loc.coordinate.latitude, lng: loc.coordinate.longitude))
        } else {
            note = "定位失败, 请在系统设置里允许定位"
        }
    }

    private func stopAndSendVoice() {
        guard let url = recorder.stop() else { return }
        Task {
            busy = true
            note = "语音上传中…"
            let link = await Uploader.upload(fileURL: url, mime: "audio/mp4")
            busy = false
            note = link == nil ? "语音上传失败" : nil
            if let link = link { onSend(.voice(link)) }
        }
    }
}

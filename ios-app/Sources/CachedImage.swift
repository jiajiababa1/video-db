import SwiftUI

/// 带内存+磁盘缓存的图片 (替代 AsyncImage: 滚动/重进页面不再重新下载)
struct CachedImage: View {
    let urlString: String?
    @State private var image: UIImage? = nil

    var body: some View {
        ZStack {
            if let img = image {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Rectangle().fill(Theme.surface2)
            }
        }
        .clipped()
        .task(id: urlString) { await load() }
    }

    private func load() async {
        guard let s = urlString, let url = URL(string: s) else { return }
        if let hit = await ImageStore.shared.get(url) {
            image = hit
        }
    }
}

actor ImageStore {
    static let shared = ImageStore()
    private let mem = NSCache<NSString, UIImage>()
    private let dir: URL = {
        let c = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("imgcache")
        try? FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        return c
    }()

    func get(_ url: URL) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let img = mem.object(forKey: key) { return img }
        let file = dir.appendingPathComponent(cacheName(url.absoluteString) + ".img")
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            mem.setObject(img, forKey: key)
            return img
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let img = UIImage(data: data) else { return nil }
        mem.setObject(img, forKey: key)
        try? data.write(to: file, options: .atomic)
        return img
    }

    private func cacheName(_ s: String) -> String {
        var h1: UInt64 = 5381
        var h2: UInt64 = 52711
        for b in s.utf8 {
            h1 = (h1 &* 33) &+ UInt64(b)
            h2 = (h2 &* 31) &+ UInt64(b)
        }
        return String(format: "%llx%llx", h1, h2)
    }
}

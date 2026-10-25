import SwiftUI
import CommonCrypto

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
        let file = dir.appendingPathComponent(md5(url.absoluteString) + ".img")
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

    private func md5(_ s: String) -> String {
        let data = Data(s.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { CC_MD5($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

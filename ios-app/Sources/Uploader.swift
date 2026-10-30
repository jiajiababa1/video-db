import Foundation

/// 聊天附件上传: 匿名文件托管 (与网站 uploadPlugin 同语义: 传文件得直链 URL)。
/// v1.6 起主通道改为 catbox 正式站 (持久保存, 不再 72 小时过期);
/// litterbox (72 小时) 与 0x0.st 仅兜底。
enum Uploader {
    static func upload(data: Data, filename: String, mime: String) async -> String? {
        if let u = await catbox(data: data, filename: filename, mime: mime) { return u }
        ErrLog.log("upload", "catbox 失败, 走兜底通道: " + filename)
        if let u = await litterbox(data: data, filename: filename, mime: mime) { return u }
        return await zeroXZero(data: data, filename: filename, mime: mime)
    }

    static func upload(fileURL: URL, mime: String) async -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return await upload(data: data, filename: fileURL.lastPathComponent, mime: mime)
    }

    private static func multipart(url: URL, fields: [(String, String)],
                                  fileField: String, filename: String, mime: String,
                                  data: Data, extraHeaders: [String: String] = [:]) async -> String? {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        let boundary = "vdb" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        var body = Data()
        for (name, value) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8Data)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8Data)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".utf8Data)
        req.httpBody = body
        guard let (d, r) = try? await URLSession.shared.data(for: req),
              (r as? HTTPURLResponse)?.statusCode == 200,
              let s = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              s.hasPrefix("https://") else { return nil }
        return s
    }

    /// catbox 正式站: files.catbox.moe 直链, 官方口径为持久保存 (单文件 ≤200MB)
    private static func catbox(data: Data, filename: String, mime: String) async -> String? {
        await multipart(url: URL(string: "https://catbox.moe/user/api.php")!,
                        fields: [("reqtype", "fileupload")],
                        fileField: "fileToUpload", filename: filename, mime: mime, data: data)
    }

    private static func litterbox(data: Data, filename: String, mime: String) async -> String? {
        await multipart(url: URL(string: "https://litterbox.catbox.moe/resources/internals/api.php")!,
                        fields: [("reqtype", "fileupload"), ("time", "72h")],
                        fileField: "fileToUpload", filename: filename, mime: mime, data: data)
    }

    private static func zeroXZero(data: Data, filename: String, mime: String) async -> String? {
        await multipart(url: URL(string: "https://0x0.st")!,
                        fields: [],
                        fileField: "file", filename: filename, mime: mime, data: data,
                        extraHeaders: ["User-Agent": "VideoDB-iOS"])
    }
}

private extension String {
    var utf8Data: Data { Data(utf8) }
}

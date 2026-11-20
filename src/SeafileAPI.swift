import Foundation

enum APIError: LocalizedError {
    case badStatus(Int, String)
    case invalidResponse
    case noToken
    case file(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .badStatus(let code, let body):
            let hint: String
            switch code {
            case 401, 403: hint = "Token 已失效，请在设置里重新获取"
            case 404: hint = "路径或资料库不存在"
            case 413: hint = "文件超过服务器单次上传限制"
            default: hint = body.prefix(160).description
            }
            return "服务器返回 \(code)：\(hint)"
        case .invalidResponse: return "服务器返回了无法解析的内容"
        case .noToken: return "未找到 Token，请在设置里登录或手动填写"
        case .file(let s): return s
        case .cancelled: return "已取消"
        }
    }
}

struct SeafItem: Identifiable, Hashable {
    var id: String
    var name: String
    var type: String
    var size: Int64
    var mtime: Int64
    var isDir: Bool { type == "dir" }
}

struct RepoInfo: Identifiable, Hashable {
    var id: String
    var name: String
    var size: Int64
}

struct UploadEntry {
    let fileURL: URL
    let relativePath: String
}

/// URLSessionTaskDelegate：只负责上报上传进度
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let handler: (Int64, Int64) -> Void
    init(handler: @escaping (Int64, Int64) -> Void) { self.handler = handler }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        handler(totalBytesSent, totalBytesExpectedToSend)
    }
}

/// 下载进度回调：已下载字节数 / 预期总字节数（-1 表示服务器未给出长度）
final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: (Int64, Int64) -> Void
    private let onComplete: (Result<URL, Error>) -> Void
    private let shouldCancel: () -> Bool
    private var movedURL: URL?

    init(onProgress: @escaping (Int64, Int64) -> Void,
         shouldCancel: @escaping () -> Bool,
         onComplete: @escaping (Result<URL, Error>) -> Void) {
        self.onProgress = onProgress
        self.shouldCancel = shouldCancel
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if shouldCancel() { downloadTask.cancel(); return }
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // 复制到自有临时位置，避免会话结束后系统清理掉原始临时文件
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("sd-dl-\(UUID().uuidString).tmp")
        do {
            try FileManager.default.copyItem(at: location, to: dest)
            movedURL = dest
        } catch {
            movedURL = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        if let error = error {
            onComplete(.failure(error))
        } else if let http = task.response as? HTTPURLResponse,
                  !(200...299).contains(http.statusCode) {
            onComplete(.failure(APIError.badStatus(http.statusCode, "")))
        } else if let url = movedURL {
            onComplete(.success(url))
        } else {
            onComplete(.failure(APIError.invalidResponse))
        }
    }
}

final class SeafileAPI {
    let server: String
    let repoID: String
    let token: String

    init(server: String, repoID: String, token: String) {
        self.server = server.hasSuffix("/") ? String(server.dropLast()) : server
        self.repoID = repoID
        self.token = token
    }

    private var repoBase: String { "\(server)/api2/repos/\(repoID)" }

    // MARK: - 请求构造

    private func repoRequest(_ path: String) throws -> URLRequest {
        guard let url = URL(string: repoBase + path) else { throw APIError.invalidResponse }
        var req = URLRequest(url: url)
        req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60
        return req
    }

    private func serverRequest(_ path: String) throws -> URLRequest {
        guard let url = URL(string: server + path) else { throw APIError.invalidResponse }
        var req = URLRequest(url: url)
        req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60
        return req
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw APIError.badStatus(http.statusCode, body)
        }
    }

    static func join(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/" + name : parent + "/" + name
    }

    static func encodePath(_ path: String) -> String {
        let p = path.hasPrefix("/") ? path : "/" + path
        return p.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? p
    }

    private func stringFromLink(_ data: Data) throws -> URL {
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? ""
        guard let url = URL(string: raw), url.scheme != nil else { throw APIError.invalidResponse }
        return url
    }

    // MARK: - 只读接口

    func accountInfo() async throws -> String {
        let req = try serverRequest("/api2/account/info/")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String else { throw APIError.invalidResponse }
        return name
    }

    func listRepos() async throws -> [RepoInfo] {
        let req = try serverRequest("/api2/repos/")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return arr.compactMap { d in
            guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
            return RepoInfo(id: id, name: name,
                            size: (d["size"] as? NSNumber)?.int64Value ?? 0)
        }
    }

    func list(path: String) async throws -> [SeafItem] {
        let req = try repoRequest("/dir/?p=\(Self.encodePath(path))")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return arr.map { d in
            SeafItem(id: (d["id"] as? String) ?? UUID().uuidString,
                     name: (d["name"] as? String) ?? "未知",
                     type: (d["type"] as? String) ?? "file",
                     size: (d["size"] as? NSNumber)?.int64Value ?? 0,
                     mtime: (d["mtime"] as? NSNumber)?.int64Value ?? 0)
        }
    }

    func uploadLink(parentDir: String) async throws -> URL {
        let req = try repoRequest("/upload-link/?p=\(Self.encodePath(parentDir))")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        return try stringFromLink(data)
    }

    func downloadLink(path: String) async throws -> URL {
        let req = try repoRequest("/file/?p=\(Self.encodePath(path))&reuse=1")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        return try stringFromLink(data)
    }

    // MARK: - 上传

    /// 把拖拽进来的文件/文件夹一次性打包成 multipart 上传到云端目录，body 写入临时文件避免大文件占用内存。
    func upload(entries: [UploadEntry], parentDir: String,
                onProgress: @escaping (Double) -> Void) async throws {
        guard !entries.isEmpty else { return }
        let link = try await uploadLink(parentDir: parentDir)

        let boundary = "----SeafileDock" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let tempBody = FileManager.default.temporaryDirectory
            .appendingPathComponent("sd-upload-\(UUID().uuidString).multipart")
        defer { try? FileManager.default.removeItem(at: tempBody) }

        guard FileManager.default.createFile(atPath: tempBody.path, contents: nil) else {
            throw APIError.file("无法创建上传临时文件")
        }
        let out = try FileHandle(forWritingTo: tempBody)
        defer { try? out.close() }

        func write(_ s: String) { out.write(Data(s.utf8)) }
        func field(_ name: String, _ value: String) {
            write("--\(boundary)\r\n")
            write("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            write("\(value)\r\n")
        }

        field("parent_dir", parentDir)
        field("replace", "1")

        for entry in entries {
            let name = entry.fileURL.lastPathComponent
                .replacingOccurrences(of: "\"", with: "_")
                .replacingOccurrences(of: "\r", with: "_")
                .replacingOccurrences(of: "\n", with: "_")
            // Seafile 的 relative_path 表示「文件要放入的相对目录」，不含文件名。
            // 若把完整路径（含文件名）传进去，服务器会按文件名再建一层目录，
            // 导致每上传一个文件就多出一个与文件同名的目录。
            let parentFolder = (entry.relativePath as NSString).deletingLastPathComponent
            if parentFolder != "." && !parentFolder.isEmpty {
                field("relative_path", parentFolder)
            }
            write("--\(boundary)\r\n")
            write("Content-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\n")
            write("Content-Type: application/octet-stream\r\n\r\n")
            let input = try FileHandle(forReadingFrom: entry.fileURL)
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                out.write(chunk)
            }
            try? input.close()
            write("\r\n")
        }
        write("--\(boundary)--\r\n")
        try out.close()

        var req = URLRequest(url: link)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("close", forHTTPHeaderField: "Connection")
        req.timeoutInterval = 7200

        let delegate = UploadProgressDelegate { sent, total in
            onProgress(total > 0 ? min(1.0, Double(sent) / Double(total)) : 0)
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, resp) = try await session.upload(for: req, fromFile: tempBody, delegate: delegate)
        try Self.check(resp, data)
    }

    // MARK: - 删除

    /// 删除云端文件或文件夹（文件夹会连同其中所有内容一起删除，不可恢复）
    func delete(path: String, isDir: Bool) async throws {
        let kind = isDir ? "dir" : "file"
        var req = try repoRequest("/\(kind)/?p=\(Self.encodePath(path))")
        req.httpMethod = "DELETE"
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
    }

    // MARK: - 下载

    func uniqueLocalURL(for name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        var index = 1
        while fm.fileExists(atPath: candidate.path) {
            let ns = name as NSString
            let base = ns.deletingPathExtension
            let ext = ns.pathExtension
            let newName = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            candidate = dir.appendingPathComponent(newName)
            index += 1
        }
        return candidate
    }

    /// 带字节级进度的单文件下载
    func downloadFile(remotePath: String, name: String, to dir: URL,
                      onProgress: ((Double) -> Void)? = nil,
                      shouldCancel: (() -> Bool)? = nil) async throws -> URL {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let link = try await downloadLink(path: remotePath)
        let temp: URL = try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadProgressDelegate(
                onProgress: { written, expected in
                    // expected 为 -1 时无法给出百分比，报 0 让界面显示"不确定"状态
                    let frac = expected > 0 ? min(1.0, Double(written) / Double(expected)) : 0
                    onProgress?(frac)
                },
                shouldCancel: shouldCancel ?? { false },
                onComplete: { result in continuation.resume(with: result) }
            )
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            session.downloadTask(with: link).resume()
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        let dest = uniqueLocalURL(for: name, in: dir)
        do {
            try FileManager.default.moveItem(at: temp, to: dest)
        } catch {
            try FileManager.default.copyItem(at: temp, to: dest)
        }
        return dest
    }

    private struct RemoteFile {
        let path: String
        let relative: String
    }

    private func collectFiles(remotePath: String, relative: String) async throws -> [RemoteFile] {
        let items = try await list(path: remotePath)
        var result: [RemoteFile] = []
        for item in items {
            let childPath = Self.join(remotePath, item.name)
            let childRel = relative.isEmpty ? item.name : relative + "/" + item.name
            if item.isDir {
                result += try await collectFiles(remotePath: childPath, relative: childRel)
            } else {
                result.append(RemoteFile(path: childPath, relative: childRel))
            }
        }
        return result
    }

    /// 递归下载整个云端文件夹到 本地目录/文件夹名/
    /// 进度按「已完成文件数 + 当前文件完成度」折算成整体百分比
    func downloadFolder(remotePath: String, name: String, to dir: URL,
                        onProgress: @escaping (Int, Int, Double) -> Void,
                        shouldCancel: @escaping () -> Bool) async throws -> URL {
        let files = try await collectFiles(remotePath: remotePath, relative: "")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let root = uniqueLocalURL(for: name, in: dir)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for (index, file) in files.enumerated() {
            if shouldCancel() { throw APIError.cancelled }
            let dest = root.appendingPathComponent(file.relative)
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            let temp = try await downloadFile(remotePath: file.path, name: dest.lastPathComponent,
                                              to: dest.deletingLastPathComponent(),
                                              onProgress: { frac in
                                                  let overall = (Double(index) + frac) / Double(max(1, files.count))
                                                  onProgress(index, files.count, overall)
                                              },
                                              shouldCancel: shouldCancel)
            // downloadFile 已按名字落到目标目录；若因重名被改名则纠正到期望路径
            if temp.path != dest.path {
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.moveItem(at: temp, to: dest)
            }
            onProgress(index + 1, files.count,
                       Double(index + 1) / Double(max(1, files.count)))
        }
        return root
    }
}

import Foundation

enum DisplayMode: String, Codable, CaseIterable, Identifiable {
    case floating = "悬空浮动"
    case pinned = "固定桌面"
    var id: String { rawValue }
}

enum SortMode: String, Codable, CaseIterable, Identifiable {
    case name = "按名称（混合）"
    case date = "按时间（混合）"
    case nameFoldersFirst = "按名称（文件夹优先）"
    case dateFoldersFirst = "按时间（文件夹优先）"
    var id: String { rawValue }
}

struct Settings: Codable, Equatable {
    // 默认值是占位符：首次运行时需在「设置」里填入自己的服务器、账号与资料库 ID。
    var serverURL: String = "https://seafile.example.com"
    var account: String = "you@example.com"
    var repoID: String = "00000000-0000-0000-0000-000000000000"
    var repoName: String = "我的云盘"
    var downloadDir: String = NSHomeDirectory() + "/Downloads"
    var manualToken: String = ""
    var displayMode: DisplayMode = .floating
    var sortMode: SortMode = .name

    init() {}

    /// 兼容旧版本存档：缺少的字段回退到默认值，避免设置被整体重置
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverURL = (try? c.decode(String.self, forKey: .serverURL)) ?? "https://seafile.example.com"
        account = (try? c.decode(String.self, forKey: .account)) ?? "you@example.com"
        repoID = (try? c.decode(String.self, forKey: .repoID)) ?? "00000000-0000-0000-0000-000000000000"
        repoName = (try? c.decode(String.self, forKey: .repoName)) ?? "我的云盘"
        downloadDir = (try? c.decode(String.self, forKey: .downloadDir)) ?? (NSHomeDirectory() + "/Downloads")
        manualToken = (try? c.decode(String.self, forKey: .manualToken)) ?? ""
        displayMode = (try? c.decode(DisplayMode.self, forKey: .displayMode)) ?? .floating
        sortMode = (try? c.decode(SortMode.self, forKey: .sortMode)) ?? .name
    }
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var settings: Settings {
        didSet { save() }
    }

    private let defaultsKey = "SeafileDock.settings.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = decoded
        } else {
            settings = Settings()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// 优先使用手动填写的 token，否则每次都从本机 Seafile 客户端数据库实时读取。
    /// 这样客户端重新登录后，重启小组件就会自动拿到新 token。
    func token() -> String {
        let manual = settings.manualToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty { return manual }
        return autoDetectToken() ?? ""
    }

    func hasToken() -> Bool { !token().isEmpty }

    /// 只读查询 ~/Seafile/.seafile-data/accounts.db
    func autoDetectToken() -> String? {
        let db = NSHomeDirectory() + "/Seafile/.seafile-data/accounts.db"
        guard FileManager.default.fileExists(atPath: db) else { return nil }
        return sqliteQuery(db: db, sql: "select token from Accounts where username='\(escapeSQL(settings.account))' limit 1;")
    }

    func autoDetectAccounts() -> [String] {
        let db = NSHomeDirectory() + "/Seafile/.seafile-data/accounts.db"
        guard FileManager.default.fileExists(atPath: db) else { return [settings.account] }
        let out = sqliteQuery(db: db, sql: "select username from Accounts order by username;") ?? ""
        let list = out.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
        return list.isEmpty ? [settings.account] : list
    }

    /// 读取客户端里配置的代理信息（仅用于设置面板展示，网络层默认跟随系统代理）
    func clientProxyInfo() -> String {
        let db = NSHomeDirectory() + "/Seafile/.seafile-data/config.db"
        guard FileManager.default.fileExists(atPath: db) else { return "跟随系统设置" }
        let host = sqliteQuery(db: db, sql: "select value from Config where key='proxy_addr' limit 1;") ?? ""
        let port = sqliteQuery(db: db, sql: "select value from Config where key='proxy_port' limit 1;") ?? ""
        return host.isEmpty ? "跟随系统设置" : "\(host):\(port)（客户端配置）"
    }

    private func escapeSQL(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }

    private func sqliteQuery(db: String, sql: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", db, sql]
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            print("[sqlite3] 启动失败: \(error)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let err = String(data: errData, encoding: .utf8) ?? ""
            print("[sqlite3] 退出码 \(process.terminationStatus): \(err)")
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 用账号密码向 Seafile 换取 token（密码不会保存）
    func requestToken(username: String, password: String, server: String? = nil) async throws -> String {
        let rawServer = server ?? settings.serverURL
        let base = rawServer.hasSuffix("/") ? String(rawServer.dropLast()) : rawServer
        guard let url = URL(string: base + "/api2/auth-token/") else {
            throw APIError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        let body = "username=\(percentEncode(username))&password=\(percentEncode(password))"
        req.httpBody = Data(body.utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try SeafileAPI.check(resp, data)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String, !token.isEmpty else {
            throw APIError.invalidResponse
        }
        return token
    }

    private func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

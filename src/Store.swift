import Foundation
import AppKit
import Combine

/// 用 ObservableObject 承载设置面板状态（当前工具链缺少 SwiftUI 宏插件，避免使用 @State）
final class SettingsDraft: ObservableObject {
    static let shared = SettingsDraft()
    @Published var draft: Settings = SettingsStore.shared.settings
    @Published var password: String = ""
    @Published var note: String = ""
    @Published var loggingIn = false

    func reset() {
        draft = SettingsStore.shared.settings
        password = ""
        note = ""
        loggingIn = false
    }
}

@MainActor
final class DockStore: ObservableObject {
    @Published var items: [SeafItem] = []
    @Published var path: String = "/"
    @Published var search: String = ""
    @Published var isLoading: Bool = false
    @Published var isBusy: Bool = false
    @Published var message: String = "正在连接…"
    @Published var isError: Bool = false
    @Published var progress: Double? = nil
    @Published var busyLabel: String = ""
    @Published var isDropTargeted: Bool = false
    @Published var showSettings: Bool = false
    @Published var showPicker: Bool = false
    @Published var repos: [RepoInfo] = []

    private var api: SeafileAPI?
    private var cancelRequested = false
    private var settingsCancellable: AnyCancellable?
    private static let statusKey = "SeafileDock.lastStatus"

    init() {
        // 设置变化（排序、显示模式、资料库…）也要刷新小组件界面
        settingsCancellable = SettingsStore.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.objectWillChange.send() }
            }
    }

    var settings: Settings { SettingsStore.shared.settings }

    var displayItems: [SeafItem] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var arr = items
        if !q.isEmpty { arr = arr.filter { $0.name.localizedCaseInsensitiveContains(q) } }
        let mode = settings.sortMode
        let foldersFirst = (mode == .nameFoldersFirst || mode == .dateFoldersFirst)
        let byDate = (mode == .date || mode == .dateFoldersFirst)
        return arr.sorted { a, b in
            // 默认完全混合排序；只有显式选择「文件夹优先」时才分组
            if foldersFirst && a.isDir != b.isDir { return a.isDir }
            if byDate && a.mtime != b.mtime { return a.mtime > b.mtime }
            return a.name.localizedCompare(b.name) == .orderedAscending
        }
    }

    var title: String {
        path == "/" ? settings.repoName : (path as NSString).lastPathComponent
    }

    var canGoUp: Bool { path != "/" }

    // MARK: - 连接

    private func ensureAPI() -> SeafileAPI? {
        let s = SettingsStore.shared.settings
        let token = SettingsStore.shared.token()
        guard !token.isEmpty else {
            message = "未找到 Token，请点右上角设置登录"
            isError = true
            showSettings = true
            return nil
        }
        let client = SeafileAPI(server: s.serverURL, repoID: s.repoID, token: token)
        api = client
        return client
    }

    func load() async {
        guard let client = ensureAPI() else {
            UserDefaults.standard.set("FAIL no-token", forKey: Self.statusKey)
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await client.list(path: path)
            items = result
            isError = false
            message = "\(result.count) 项 · 云端直连，不占用本地空间"
            UserDefaults.standard.set("OK path=\(path) count=\(result.count)", forKey: Self.statusKey)
        } catch {
            UserDefaults.standard.set("FAIL \(error.localizedDescription)", forKey: Self.statusKey)
            fail(error)
        }
    }

    func refresh() async { await load() }

    func enter(_ item: SeafItem) async {
        guard item.isDir else { return }
        path = SeafileAPI.join(path, item.name)
        search = ""
        await load()
    }

    func goUp() async {
        guard canGoUp else { return }
        let parent = (path as NSString).deletingLastPathComponent
        path = parent.isEmpty ? "/" : parent
        search = ""
        await load()
    }

    func goRoot() async {
        path = "/"
        search = ""
        await load()
    }

    // MARK: - 上传

    func handleDrop(_ providers: [NSItemProvider]) async {
        var urls: [URL] = []
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier("public.file-url") else { continue }
            if let url = await resolveFileURL(provider) { urls.append(url) }
        }
        guard !urls.isEmpty else {
            message = "没有识别到可上传的文件"; isError = true; return
        }
        await upload(urls)
    }

    private func resolveFileURL(_ provider: NSItemProvider) async -> URL? {
        let item: (any NSSecureCoding)? = await withCheckedContinuation { (continuation: CheckedContinuation<(any NSSecureCoding)?, Never>) in
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                continuation.resume(returning: item)
            }
        }
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let str = item as? String { return URL(string: str) }
        return nil
    }

    /// 把拖进来的文件/文件夹展开成上传条目（文件夹保留相对路径）
    private func expand(_ urls: [URL]) -> [UploadEntry] {
        let fm = FileManager.default
        var entries: [UploadEntry] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let enumerator = fm.enumerator(at: url,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) else { continue }
                for case let child as URL in enumerator {
                    var childDir: ObjCBool = false
                    fm.fileExists(atPath: child.path, isDirectory: &childDir)
                    if childDir.boolValue { continue }
                    let suffix = String(child.path.dropFirst(url.path.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let relative = url.lastPathComponent + "/" + suffix
                    entries.append(UploadEntry(fileURL: child, relativePath: relative))
                }
            } else {
                entries.append(UploadEntry(fileURL: url, relativePath: url.lastPathComponent))
            }
        }
        return entries
    }

    func upload(_ urls: [URL]) async {
        guard let client = ensureAPI() else { return }
        let entries = expand(urls)
        guard !entries.isEmpty else {
            message = "所选内容里没有可上传的文件"; isError = true; return
        }
        let bytes = entries.reduce(Int64(0)) { sum, e in
            let attrs = try? FileManager.default.attributesOfItem(atPath: e.fileURL.path)
            return sum + ((attrs?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        let sizeText = Self.formatSize(bytes)
        isBusy = true
        isError = false
        progress = 0
        busyLabel = "上传 \(entries.count) 个文件（\(sizeText)）到 \(path == "/" ? "根目录" : title)…"
        message = busyLabel
        do {
            try await client.upload(entries: entries, parentDir: path) { [weak self] fraction in
                Task { @MainActor in self?.progress = fraction }
            }
            message = "已上传 \(entries.count) 个文件（\(sizeText)）"
            progress = nil
            isBusy = false
            await load()
        } catch {
            isBusy = false
            progress = nil
            fail(error)
        }
    }

    /// 通过系统文件选择器上传
    func pickAndUpload() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "选择要上传到云端 \(path) 的文件或文件夹"
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            panel.begin { response in continuation.resume(returning: response) }
        }
        guard result == .OK else { return }
        await upload(panel.urls)
    }

    // MARK: - 下载

    func download(_ item: SeafItem) async {
        guard let client = ensureAPI() else { return }
        let dir = URL(fileURLWithPath: settings.downloadDir, isDirectory: true)
        let remote = SeafileAPI.join(path, item.name)
        cancelRequested = false
        isBusy = true
        isError = false
        progress = nil

        if item.isDir {
            busyLabel = "正在读取文件夹结构…"
            message = busyLabel
            do {
                let root = try await client.downloadFolder(
                    remotePath: remote, name: item.name, to: dir,
                    onFileDone: { [weak self] done, total in
                        Task { @MainActor in
                            self?.progress = Double(done) / Double(max(1, total))
                            self?.busyLabel = "下载中 \(done)/\(total) 个文件"
                            self?.message = self?.busyLabel ?? ""
                        }
                    },
                    shouldCancel: { [weak self] in self?.cancelRequested ?? false }
                )
                isBusy = false
                progress = nil
                message = "已下载到 \(root.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([root])
            } catch {
                isBusy = false
                progress = nil
                fail(error)
            }
        } else {
            busyLabel = "下载 \(item.name)…"
            message = busyLabel
            do {
                let dest = try await client.downloadFile(remotePath: remote,
                                                        name: item.name, to: dir)
                isBusy = false
                message = "已下载 \(item.name)（\(Self.formatSize(item.size))）"
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            } catch {
                isBusy = false
                fail(error)
            }
        }
    }

    func cancel() {
        cancelRequested = true
        message = "正在取消…"
    }

    // MARK: - 删除

    /// 右键删除入口：先弹确认框，确认后再真正删除（云端操作不可恢复）
    func confirmDelete(_ item: SeafItem) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        if item.isDir {
            alert.messageText = "删除文件夹「\(item.name)」？"
            alert.informativeText = "该文件夹及其中的全部内容都会从云端删除，且无法恢复。"
        } else {
            alert.messageText = "删除文件「\(item.name)」？"
            alert.informativeText = "该文件会从云端删除，且无法恢复。"
        }
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        // 删除不可恢复：把「取消」设为默认按钮，回车不会误删
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\r"
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        Task { @MainActor in await self.delete(item) }
    }

    private func delete(_ item: SeafItem) async {
        guard let client = ensureAPI() else { return }
        let remote = SeafileAPI.join(path, item.name)
        isBusy = true
        isError = false
        busyLabel = "正在删除 \(item.name)…"
        message = busyLabel
        do {
            try await client.delete(path: remote, isDir: item.isDir)
            isBusy = false
            message = "已删除 \(item.name)"
            await load()
        } catch {
            isBusy = false
            fail(error)
        }
    }

    // MARK: - 设置辅助

    func loadRepos() async {
        guard let client = ensureAPI() else { return }
        do { repos = try await client.listRepos() } catch { fail(error) }
    }

    func testConnection() async {
        guard let client = ensureAPI() else { return }
        do {
            let name = try await client.accountInfo()
            let _ = try await client.list(path: "/")
            message = "连接正常：\(name)"
            isError = false
        } catch { fail(error) }
    }

    func applySettings() async {
        api = nil
        path = "/"
        await load()
    }

    // MARK: - 工具

    private func fail(_ error: Error) {
        message = error.localizedDescription
        isError = true
    }

    static func formatSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var i = 0
        while value >= 1024 && i < units.count - 1 { value /= 1024; i += 1 }
        if i == 0 { return "\(bytes) B" }
        return String(format: "%.1f %@", value, units[i])
    }

    static func formatDate(_ timestamp: Int64) -> String {
        guard timestamp > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.dateFormat = "yy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }
}

// MARK: - 命令行自检（--self-test，不启动界面，只做只读验证）

enum SelfTest {
    /// 直接写文件描述符，避免 stdout 缓冲导致进程被结束时丢失输出
    private static func emit(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    static func run() async {
        let settings = SettingsStore.shared
        let db = NSHomeDirectory() + "/Seafile/.seafile-data/accounts.db"
        emit("HOME=\(NSHomeDirectory())")
        emit("DB_EXISTS=\(FileManager.default.fileExists(atPath: db))")
        let token = settings.token()
        emit("TOKEN_LEN=\(token.count)")
        guard !token.isEmpty else {
            emit("RESULT=FAIL(no token)")
            return
        }
        let api = SeafileAPI(server: settings.settings.serverURL,
                             repoID: settings.settings.repoID,
                             token: token)
        do {
            emit("ACCOUNT=\(try await api.accountInfo())")
            let items = try await api.list(path: "/")
            emit("ROOT_COUNT=\(items.count)")
            for item in items.prefix(4) {
                emit("  \(item.isDir ? "DIR " : "FILE") \(item.name)")
            }
            let link = try await api.uploadLink(parentDir: "/")
            emit("UPLOAD_LINK_OK=\(link.host ?? "")")

            if let dir = items.first(where: { $0.isDir }) {
                let sub = try await api.list(path: "/" + dir.name)
                if let file = sub.first(where: { !$0.isDir && $0.size < 200_000 }) {
                    let tmp = URL(fileURLWithPath: NSTemporaryDirectory() + "sd-selftest")
                    let dest = try await api.downloadFile(
                        remotePath: "/" + dir.name + "/" + file.name,
                        name: file.name, to: tmp)
                    let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
                    let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                    emit("DOWNLOAD_OK=\(file.name) bytes=\(size) expected=\(file.size)")
                    try? FileManager.default.removeItem(at: tmp)
                }
            }
            // 删除链路验证：上传临时文件 → 删除 → 确认已不在目录列表
            let probeName = "__sd_delete_probe__.txt"
            let probeURL = URL(fileURLWithPath: NSTemporaryDirectory() + probeName)
            try? "delete probe".write(to: probeURL, atomically: true, encoding: .utf8)
            let probe = UploadEntry(fileURL: probeURL, relativePath: probeName)
            try await api.upload(entries: [probe], parentDir: "/") { _ in }
            emit("DELETE_PROBE_UPLOADED=1")
            try await api.delete(path: "/" + probeName, isDir: false)
            let after = try await api.list(path: "/")
            emit("DELETE_PROBE_GONE=\(!after.contains { $0.name == probeName })")
            try? FileManager.default.removeItem(at: probeURL)

            let repos = try await api.listRepos()
            emit("REPOS=\(repos.count)")
            emit("RESULT=PASS")
        } catch {
            emit("RESULT=FAIL(\(error.localizedDescription))")
        }
    }
}

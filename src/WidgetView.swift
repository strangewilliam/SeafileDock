import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 根视图

struct WidgetRoot: View {
    @EnvironmentObject var store: DockStore
    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        ZStack {
            VisualEffectBackground()
            VStack(spacing: 0) {
                HeaderBar()
                ToolBar()
                SearchBar()
                Divider().opacity(0.5)
                FileListView()
                Divider().opacity(0.5)
                StatusBar()
            }
            if store.isDropTargeted {
                DropOverlay()
            }
        }
        .frame(minWidth: 320, minHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $store.isDropTargeted) { providers in
            Task { await store.handleDrop(providers) }
            return true
        }
        .onExitCommand { Self.hidePanel() }
        .sheet(isPresented: $store.showSettings) {
            SettingsView()
                .environmentObject(store)
                .environmentObject(settingsStore)
        }
    }

    static func hidePanel() {
        NSApplication.shared.windows.first(where: { $0 is FloatingPanel })?.orderOut(nil)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - 顶部标题栏（可拖动窗口）

struct WindowDragHandle: NSViewRepresentable {
    var isMovable: Bool = true

    func makeNSView(context: Context) -> DragNSView {
        let view = DragNSView()
        view.isMovable = isMovable
        return view
    }
    func updateNSView(_ nsView: DragNSView, context: Context) {
        nsView.isMovable = isMovable
    }
}

final class DragNSView: NSView {
    var isMovable = true
    override func mouseDown(with event: NSEvent) {
        if isMovable {
            window?.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }
    override var acceptsFirstResponder: Bool { false }
}

struct HeaderBar: View {
    @EnvironmentObject var store: DockStore

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 17))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.settings.repoName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("\(store.settings.displayMode.rawValue) · \(store.path)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            IconButton(system: "gearshape", help: "设置") { store.showSettings = true }
            IconButton(system: "xmark", help: "隐藏面板（菜单栏图标可再次打开）") {
                WidgetRoot.hidePanel()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(WindowDragHandle(isMovable: store.settings.displayMode == .floating))
        .background(Color.primary.opacity(0.04))
    }
}

struct IconButton: View {
    let system: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

// MARK: - 工具条

struct ToolBar: View {
    @EnvironmentObject var store: DockStore

    var body: some View {
        HStack(spacing: 4) {
            Button {
                Task { await store.goUp() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(!store.canGoUp)
            .help("返回上一级")

            Button {
                Task { await store.goRoot() }
            } label: {
                Image(systemName: "house")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("回到 tongbu 根目录")

            Text(store.path == "/" ? "/" : store.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            IconButton(system: "arrow.clockwise", help: "刷新") {
                Task { await store.refresh() }
            }
            Menu {
                ForEach(SortMode.allCases) { mode in
                    Button {
                        var updated = SettingsStore.shared.settings
                        updated.sortMode = mode
                        SettingsStore.shared.settings = updated
                    } label: {
                        HStack {
                            Text(mode.rawValue)
                            if store.settings.sortMode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 20)
            }
            .buttonStyle(.borderless)
            .frame(width: 26)
            .help("排序方式：\(store.settings.sortMode.rawValue)")
            IconButton(system: "plus.circle", help: "选择文件上传到当前目录") {
                Task { await store.pickAndUpload() }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

// MARK: - 搜索

struct SearchBar: View {
    @EnvironmentObject var store: DockStore

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("搜索当前目录…", text: $store.search)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
            if !store.search.isEmpty {
                Button { store.search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.035))
    }
}

// MARK: - 文件列表

struct FileListView: View {
    @EnvironmentObject var store: DockStore

    var body: some View {
        ZStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.displayItems) { item in
                        FileRow(item: item)
                        Divider().opacity(0.28).padding(.leading, 40)
                    }
                }
                .padding(.vertical, 3)
            }

            if store.isLoading && store.items.isEmpty {
                ProgressView().controlSize(.small)
            }
            if !store.isLoading && store.items.isEmpty && !store.isError {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 24)).foregroundStyle(.secondary)
                    Text("这个目录是空的").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if !store.isLoading && store.displayItems.isEmpty && !store.items.isEmpty {
                Text("没有匹配的文件").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FileRow: View {
    @EnvironmentObject var store: DockStore
    let item: SeafItem

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: item.isDir ? "folder.fill" : icon(for: item.name))
                .font(.system(size: 14))
                .foregroundStyle(item.isDir ? Color.accentColor : Color.secondary)
                .frame(width: 19)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.isDir
                     ? "文件夹 · \(DockStore.formatDate(item.mtime))"
                     : "\(DockStore.formatSize(item.size)) · \(DockStore.formatDate(item.mtime))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                Task { await store.download(item) }
            } label: {
                Image(systemName: item.isDir ? "square.and.arrow.down" : "arrow.down.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor.opacity(0.85))
            }
            .buttonStyle(.borderless)
            .help(item.isDir ? "下载整个文件夹到 \(store.settings.downloadDir)" : "下载到 \(store.settings.downloadDir)")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            Task {
                if item.isDir { await store.enter(item) }
                else { await store.download(item) }
            }
        }
        .contextMenu {
            Button(item.isDir ? "进入文件夹" : "下载文件") {
                Task { item.isDir ? await store.enter(item) : await store.download(item) }
            }
            Button("下载\(item.isDir ? "整个文件夹" : "")到下载目录") {
                Task { await store.download(item) }
            }
            Divider()
            Button("复制名称") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.name, forType: .string)
            }
        }
    }

    private func icon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "py", "sh", "jl", "c", "cpp", "f", "f90", "m", "js", "swift", "ipynb":
            return "chevron.left.forwardslash.chevron.right"
        case "png", "jpg", "jpeg", "gif", "tif", "tiff", "pdf", "svg":
            return "photo.fill"
        case "zip", "tar", "gz", "bz2", "7z", "rar":
            return "doc.zipper"
        case "txt", "md", "csv", "dat", "out", "log", "inp":
            return "doc.text.fill"
        default:
            return "doc.fill"
        }
    }
}

// MARK: - 状态栏

struct StatusBar: View {
    @EnvironmentObject var store: DockStore

    var body: some View {
        HStack(spacing: 6) {
            if store.isBusy {
                ProgressView().controlSize(.small).scaleEffect(0.72).frame(width: 12, height: 12)
            } else {
                Circle()
                    .fill(store.isError ? Color.red : Color.green)
                    .frame(width: 6, height: 6)
            }
            Text(store.message)
                .font(.system(size: 9.5))
                .foregroundStyle(store.isError ? Color.red : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 3)
            if let p = store.progress {
                ProgressView(value: p).frame(width: 56)
                Text("\(Int(p * 100))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if store.isBusy {
                Button("取消") { store.cancel() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 9.5))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.035))
    }
}

// MARK: - 拖放高亮

struct DropOverlay: View {
    @EnvironmentObject var store: DockStore

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(0.16))
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .padding(5)
            VStack(spacing: 9) {
                Image(systemName: "arrow.up.doc.fill").font(.system(size: 30))
                Text("松开即可上传")
                    .font(.system(size: 14, weight: .semibold))
                Text("上传到云端 \(store.path == "/" ? "tongbu 根目录" : store.path)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Text("文件夹会保持原有目录结构")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.accentColor)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 设置面板

struct SettingsView: View {
    @EnvironmentObject var store: DockStore
    @EnvironmentObject var settingsStore: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var model: SettingsDraft = SettingsDraft.shared

    private var accounts: [String] {
        var list = SettingsStore.shared.autoDetectAccounts()
        if !list.contains(model.draft.account) { list.append(model.draft.account) }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("小组件设置").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(.borderless)
            }
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    group("连接") {
                        labeled("服务器") {
                            TextField("https://seafile.example.com", text: $model.draft.serverURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                        }
                        labeled("账号") {
                            Picker("", selection: $model.draft.account) {
                                ForEach(accounts, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                        }
                        HStack(spacing: 6) {
                            Image(systemName: SettingsStore.shared.autoDetectToken() != nil
                                  ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(SettingsStore.shared.autoDetectToken() != nil ? Color.green : Color.orange)
                            Text(SettingsStore.shared.autoDetectToken() != nil
                                 ? "已从本机 Seafile 客户端自动读取到 Token" : "未能从客户端读取到 Token")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        labeled("手动 Token") {
                            SecureField("留空则自动使用客户端 Token", text: $model.draft.manualToken)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                        }
                        HStack {
                            SecureField("账号密码（仅用于换取 Token，不保存）", text: $model.password)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                            Button(model.loggingIn ? "…" : "获取 Token") {
                                Task { await login() }
                            }
                            .disabled(model.loggingIn || model.password.isEmpty || model.draft.account.isEmpty)
                        }
                        Text("客户端重新登录后，重启本小组件即可自动同步新 Token。")
                            .font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }

                    group("目标资料库") {
                        HStack {
                            Picker("", selection: $model.draft.repoID) {
                                ForEach(store.repos) { repo in
                                    Text("\(repo.name)  (\(DockStore.formatSize(repo.size)))").tag(repo.id)
                                }
                                if !store.repos.contains(where: { $0.id == model.draft.repoID }) {
                                    Text(model.draft.repoName).tag(model.draft.repoID)
                                }
                            }
                            .labelsHidden()
                            Button("刷新列表") { Task { await store.loadRepos() } }
                                .buttonStyle(.borderless)
                                .font(.system(size: 10))
                        }
                        Text("ID: \(model.draft.repoID)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    group("下载位置") {
                        HStack {
                            Text(model.draft.downloadDir)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("更改…") { chooseDownloadDir() }
                                .buttonStyle(.borderless).font(.system(size: 10))
                        }
                        Text("代理：\(SettingsStore.shared.clientProxyInfo())（网络自动跟随系统设置）")
                            .font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }

                    group("显示与排序") {
                        labeled("显示模式") {
                            Picker("", selection: $model.draft.displayMode) {
                                ForEach(DisplayMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .labelsHidden()
                        }
                        Text("悬空浮动：置顶、可拖动；固定桌面：位置锁定、不置顶，会被其他窗口遮住，显示桌面时可见，依然可以点按操作。")
                            .font(.system(size: 9.5)).foregroundStyle(.secondary)
                        labeled("排序方式") {
                            Picker("", selection: $model.draft.sortMode) {
                                ForEach(SortMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .labelsHidden()
                        }
                        Text("默认按名称把文件夹与文件混合排序，不再强制分组。")
                            .font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }

                    if !model.note.isEmpty {
                        Text(model.note)
                            .font(.system(size: 10.5))
                            .foregroundStyle(model.note.hasPrefix("✓") ? Color.green : Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider().padding(.vertical, 8)
            HStack {
                Button("测试连接") {
                    Task {
                        settingsStore.settings = model.draft
                        NotificationCenter.default.post(name: .seafileDockDisplayModeChanged, object: nil)
                        await store.testConnection()
                        model.note = store.isError ? "✗ \(store.message)" : "✓ \(store.message)"
                    }
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    if let repo = store.repos.first(where: { $0.id == model.draft.repoID }) {
                        model.draft.repoName = repo.name
                    }
                    settingsStore.settings = model.draft
                    NotificationCenter.default.post(name: .seafileDockDisplayModeChanged, object: nil)
                    Task { await store.applySettings() }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 430, height: 540)
        .onAppear {
            model.reset()
            Task { await store.loadRepos() }
        }
    }

    private func login() async {
        model.loggingIn = true
        defer { model.loggingIn = false }
        do {
            let token = try await settingsStore.requestToken(username: model.draft.account,
                                                           password: model.password,
                                                           server: model.draft.serverURL)
            model.draft.manualToken = token
            model.note = "✓ 已获取 Token，点「保存」生效"
            model.password = ""
        } catch {
            model.note = "✗ \(error.localizedDescription)"
        }
    }

    private func chooseDownloadDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择下载文件的保存位置"
        if panel.runModal() == .OK, let url = panel.url {
            model.draft.downloadDir = url.path
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 10.5)).frame(width: 68, alignment: .leading)
            content()
        }
    }
}

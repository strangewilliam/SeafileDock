import AppKit
import SwiftUI
import CoreGraphics
import Dispatch

extension Notification.Name {
    static let seafileDockDisplayModeChanged = Notification.Name("SeafileDock.displayModeChanged")
}

@main
struct SeafileDockMain {
    private static var retainedDelegate: AppDelegate?

    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            let group = DispatchGroup()
            group.enter()
            Task { await SelfTest.run(); group.leave() }
            while group.wait(timeout: .now() + 0.05) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // 不显示 Dock 图标
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private var store: DockStore!
    private var hosting: NSHostingView<AnyView>!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let dockStore = DockStore()
        store = dockStore

        let root = AnyView(
            WidgetRoot()
                .environmentObject(dockStore)
                .environmentObject(SettingsStore.shared)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
        hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        panel = FloatingPanel()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 560))
        container.wantsLayer = true
        panel.contentView = container
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        panel.setFrame(Self.restoredFrame(), display: false)
        panel.applyMode(SettingsStore.shared.settings.displayMode)
        setupStatusItem()

        NotificationCenter.default.addObserver(self, selector: #selector(saveFrame),
                                               name: NSWindow.didMoveNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(saveFrame),
                                               name: NSWindow.didResizeNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(applyDisplayMode),
                                               name: .seafileDockDisplayModeChanged, object: nil)

        panel.makeKeyAndOrderFront(nil)
        if SettingsStore.shared.settings.displayMode == .floating {
            NSApp.activate(ignoringOtherApps: true)
        }

        Task { @MainActor in
            await dockStore.load()
        }
    }

    // MARK: 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "cloud.fill",
                               accessibilityDescription: "Seafile tongbu 云盘小组件")
        button.image?.isTemplate = true
        button.toolTip = "tongbu 云盘小组件（左键显示/隐藏，右键菜单）"
        button.action = #selector(statusClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePanel()
        }
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        addMenuItem(menu, panel.isVisible ? "隐藏面板" : "显示面板", #selector(togglePanel))
        addMenuItem(menu, "刷新目录", #selector(refreshAction), "r")
        let isFloating = SettingsStore.shared.settings.displayMode == .floating
        addMenuItem(menu, isFloating ? "切换为「固定桌面」" : "切换为「悬空浮动」", #selector(toggleMode))
        menu.addItem(.separator())
        addMenuItem(menu, "设置…", #selector(openSettings), ",")
        addMenuItem(menu, "在 Finder 打开下载目录", #selector(openDownloadDir))
        menu.addItem(.separator())
        addMenuItem(menu, "退出", #selector(quit), "q")
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func addMenuItem(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func toggleMode() {
        var current = SettingsStore.shared.settings
        current.displayMode = (current.displayMode == .floating) ? .pinned : .floating
        SettingsStore.shared.settings = current
        NotificationCenter.default.post(name: .seafileDockDisplayModeChanged, object: nil)
    }

    @objc private func applyDisplayMode() {
        let mode = SettingsStore.shared.settings.displayMode
        panel.applyMode(mode)
        if mode == .floating {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            panel.orderFrontRegardless()
        }
    }

    @objc private func refreshAction() {
        Task { @MainActor in await store.refresh() }
    }

    @objc private func openSettings() {
        if !panel.isVisible { togglePanel() }
        Task { @MainActor in store.showSettings = true }
    }

    @objc private func openDownloadDir() {
        let dir = URL(fileURLWithPath: SettingsStore.shared.settings.downloadDir)
        NSWorkspace.shared.open(dir)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: 窗口位置

    @objc private func saveFrame() {
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "SeafileDock.frame.v1")
    }

    private static func restoredFrame() -> NSRect {
        if let saved = UserDefaults.standard.string(forKey: "SeafileDock.frame.v1") {
            let rect = NSRectFromString(saved)
            if rect.width >= 300 && rect.height >= 280 { return rect }
        }
        let screen = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = 380
        let height: CGFloat = 560
        return NSRect(x: screen.maxX - width - 22,
                      y: screen.maxY - height - 18,
                      width: width, height: height)
    }
}

/// 常驻桌面的浮动面板：置顶、可拖动、跨 Space、不抢焦点
final class FloatingPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
                   styleMask: [.borderless, .resizable, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        minSize = NSSize(width: 330, height: 320)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
    }

    /// 悬空浮动：置顶、可拖动；固定桌面：位置锁定、不置顶，被其他窗口自然遮住。
    /// 注意：不能用系统桌面层（desktopWindow）——App 非前台时该层窗口收不到鼠标事件，
    /// 会导致「看得见点不动」。普通窗口层同样会被其他窗口遮住，但可正常交互。
    func applyMode(_ mode: DisplayMode) {
        ignoresMouseEvents = false
        switch mode {
        case .floating:
            level = .floating
            isMovableByWindowBackground = true
            collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        case .pinned:
            level = .normal
            isMovableByWindowBackground = false
            collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        }
    }

    /// 后台常驻 App 的窗口收到点击时先激活自己，保证 SwiftUI 控件正常响应
    override func mouseDown(with event: NSEvent) {
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        super.mouseDown(with: event)
    }
}

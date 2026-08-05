import AppKit
import AppUpdater
import UniformTypeIdentifiers

private enum AppWindowMetrics {
    static let defaultContentSize = NSSize(width: 1120, height: 760)
    static let minimumContentSize = NSSize(width: 760, height: 480)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, NSMenuDelegate {
    private static let terminalContentTypes = [
        UTType.unixExecutable,
        UTType(importedAs: "com.apple.terminal.shell-script")
    ]
    private static let previousTerminalHandlersDefaultsKey = "previousTerminalHandlerURLs"
    private let updater = AppUpdater(owner: "automic-vault", repo: "vaultty")
    private var window: NSWindow?
    private var controller: TerminalViewController?
    private var titleToolbar: NSToolbar?
    private var pendingOpenURLs: [URL] = []
    private var stagedUpdate: Update?
    private var updateCheckTask: Task<Void, Never>?
    private weak var defaultTerminalMenuItem: NSMenuItem?
    private weak var remoteAccessMenuItem: NSMenuItem?
    private weak var remoteTabsMenu: NSMenu?
    private let remoteAccessController = MacRemoteAccessController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        guard prepareSessionService() else {
            NSApp.terminate(nil)
            return
        }

        let args = ProcessInfo.processInfo.arguments
        let selfTestCommand = args.enumerated().first { $0.element == "--self-test" }
            .flatMap { index, _ in args.indices.contains(index + 1) ? args[index + 1] : nil }
        let controller = TerminalViewController(selfTestCommand: selfTestCommand)
        controller.loadViewIfNeeded()
        controller.onInstallStagedUpdate = { [weak self] in
            self?.confirmInstallStagedUpdate()
        }
        self.controller = controller

        let styleMask: NSWindow.StyleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
            .fullSizeContentView
        ]
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: AppWindowMetrics.defaultContentSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "Portal"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isRestorable = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.delegate = self
        let toolbar = NSToolbar(identifier: .vaulttyTitlebar)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        titleToolbar = toolbar
        window.minSize = NSWindow.frameRect(
            forContentRect: NSRect(origin: .zero, size: AppWindowMetrics.minimumContentSize),
            styleMask: styleMask
        ).size
        window.contentMinSize = AppWindowMetrics.minimumContentSize
        window.setContentSize(AppWindowMetrics.defaultContentSize)
        window.center()
        if let nativeContentView = window.contentView {
            controller.view.frame = nativeContentView.bounds
            controller.view.autoresizingMask = [.width, .height]
            nativeContentView.addSubview(controller.view)
        }
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        controller.windowDidAttach()
        openPendingURLs()
        if selfTestCommand == nil {
            checkForUpdates()
            remoteAccessController.startIfEnabled()
        }
    }

    private func prepareSessionService() -> Bool {
        do {
            switch try PtySession.prepareLocalDaemon() {
            case .ready:
                return true
            case .previous:
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Secure Session Service Update Required"
                alert.informativeText = """
                    Portal found a previous session service that cannot enforce the current security policy. Switching secures new connections, but detached sessions held by the previous service will no longer be reachable.
                    """
                alert.addButton(withTitle: "Switch Securely")
                alert.addButton(withTitle: "Keep Existing Sessions")
                alert.addButton(withTitle: "Quit Portal")
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    return switchToSecureSessionService()
                case .alertSecondButtonReturn:
                    PtySession.allowPreviousDaemonForThisLaunch()
                    return true
                default:
                    return false
                }
            case .incompatible:
                return requireSecureSessionServiceSwitch(
                    message: "The running Portal session service is not protocol-compatible with this version."
                )
            case .untrusted:
                return requireSecureSessionServiceSwitch(
                    message: "The process listening on Portal’s private session socket cannot be verified as a signed Portal session service."
                )
            }
        } catch {
            showSessionServiceError(
                title: "Portal Could Not Prepare Its Session Service",
                error: error
            )
            return false
        }
    }

    private func requireSecureSessionServiceSwitch(message: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Session Service Cannot Be Used"
        alert.informativeText = """
            \(message)

            Portal can atomically switch the socket to its signed session service. Detached sessions held by the existing process will no longer be reachable.
            """
        alert.addButton(withTitle: "Switch Securely")
        alert.addButton(withTitle: "Quit Portal")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        return switchToSecureSessionService()
    }

    private func switchToSecureSessionService() -> Bool {
        do {
            try PtySession.replaceLocalDaemon()
            return true
        } catch {
            showSessionServiceError(
                title: "Portal Could Not Switch Session Services",
                error: error
            )
            return false
        }
    }

    private func showSessionServiceError(title: String, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = """
            \(error.localizedDescription)

            Portal did not kill or unlink the existing service. Quit Portal, finish any sessions you need to preserve, and try again.
            """
        alert.addButton(withTitle: "Quit Portal")
        alert.runModal()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        _ = openURLs(urls)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        openURLs([URL(fileURLWithPath: filename)])
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let didOpen = openURLs(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: didOpen ? .success : .failure)
    }

    private func openURLs(_ urls: [URL]) -> Bool {
        let openItems = urls.compactMap(Self.openItem)
        guard !openItems.isEmpty else { return false }

        if controller == nil {
            pendingOpenURLs.append(contentsOf: urls)
            return true
        }

        openItems.forEach(open)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller?.windowDidBecomeActive()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        controller?.windowDidBecomeActive()
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        controller?.beginWindowResizeTooltip()
    }

    func windowDidResize(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        controller?.updateWindowResizeTooltip()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        controller?.endWindowResizeTooltip()
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        updateCheckTask?.cancel()
        controller?.stopAllSessions()
    }

    private func checkForUpdates() {
        guard stagedUpdate == nil, updateCheckTask == nil else { return }
        updateCheckTask = Task { @MainActor in
            defer { updateCheckTask = nil }
            do {
                guard !Task.isCancelled, let update = try await updater.check() else {
                    return
                }
                stagedUpdate = update
                controller?.setUpdateStaged(true)
            } catch {
                NSLog("Portal update check failed: \(error.localizedDescription)")
            }
        }
    }

    private func confirmInstallStagedUpdate() {
        guard let stagedUpdate else { return }

        let alert = NSAlert()
        alert.messageText = "Install update?"
        alert.informativeText = "Portal will quit, install \(stagedUpdate.assetName), and relaunch."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Cancel")

        if let window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.install(stagedUpdate)
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            install(stagedUpdate)
        }
    }

    private func install(_ update: Update) {
        controller?.setUpdateInstallInProgress(true)
        Task { @MainActor in
            do {
                try await update.installAndRelaunch()
            } catch {
                controller?.setUpdateInstallInProgress(false)
                presentUpdateInstallError(error)
            }
        }
    }

    private func presentUpdateInstallError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "Update failed"
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc private func closeActiveTabOrWindow(_ sender: Any?) {
        guard let controller else {
            window?.performClose(sender)
            return
        }
        controller.closeActiveTabOrWindow(sender)
    }

    @objc private func newTab(_ sender: Any?) {
        controller?.newTab(sender)
    }

    @objc private func newRelayTab(_ sender: NSMenuItem) {
        guard let mac = sender.representedObject as? RemoteMac else {
            NSSound.beep()
            return
        }
        controller?.newRelayTab(on: mac)
    }

    @objc private func clearActiveTab(_ sender: Any?) {
        controller?.clearActiveTab(sender)
    }

    @objc private func clearCommandHistory(_ sender: Any?) {
        controller?.clearCommandHistory(sender)
    }

    @objc private func reopenClosedTab(_ sender: Any?) {
        controller?.reopenClosedTab(sender)
    }

    @objc private func killClosedTabs(_ sender: Any?) {
        controller?.killClosedTabs(sender)
    }

    @objc private func findInHistory(_ sender: Any?) {
        controller?.findInHistory(sender)
    }

    @objc private func findNextInHistory(_ sender: Any?) {
        controller?.findNextInHistory(sender)
    }

    @objc private func findPreviousInHistory(_ sender: Any?) {
        controller?.findPreviousInHistory(sender)
    }


    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    @objc private func selectPreviousTab(_ sender: Any?) {
        controller?.selectPreviousTab(sender)
    }

    @objc private func selectNextTab(_ sender: Any?) {
        controller?.selectNextTab(sender)
    }

    private func openPendingURLs() {
        guard !pendingOpenURLs.isEmpty else { return }
        let urls = pendingOpenURLs
        pendingOpenURLs.removeAll()
        _ = openURLs(urls)
    }

    private enum OpenItem {
        case directory(URL)
        case executable(URL)
    }

    private func open(_ item: OpenItem) {
        guard let controller else { return }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        switch item {
        case .directory(let url):
            controller.newTab(at: url)
        case .executable(let url):
            controller.newTab(
                at: url.deletingLastPathComponent(),
                running: shellQuote(url.path),
                exitsShellAfterCompletion: url.pathExtension.caseInsensitiveCompare("cmd") == .orderedSame
            )
        }
    }

    private static func openItem(from url: URL) -> OpenItem? {
        guard url.isFileURL else { return nil }
        let standardizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory) else {
            return nil
        }
        return isDirectory.boolValue ? .directory(standardizedURL) : .executable(standardizedURL)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        []
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        []
    }

    private func makeMainMenu() -> NSMenu {
        let menu = NSMenu(title: "Main Menu")
        menu.addItem(makeAppMenuItem())
        menu.addItem(makeTabsMenuItem())
        menu.addItem(makeEditMenuItem())
        menu.addItem(makeWindowMenuItem())
        return menu
    }

    private func makeAppMenuItem() -> NSMenuItem {
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Portal")
        let appName = ProcessInfo.processInfo.processName

        appMenu.addItem(
            withTitle: "About \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())

        let preferencesItem = NSMenuItem(title: "Preferences", action: nil, keyEquivalent: "")
        let preferencesMenu = NSMenu(title: "Preferences")
        for effect in BackgroundBlurEffect.allCases {
            let item = preferencesMenu.addItem(
                withTitle: effect.title,
                action: #selector(selectBackgroundBlurEffect(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = effect.rawValue
            item.state = effect == BackgroundBlurEffect.preferred ? .on : .off
        }
        preferencesItem.submenu = preferencesMenu
        appMenu.addItem(preferencesItem)
        let remoteAccessItem = appMenu.addItem(
            withTitle: "Enable Remote Access",
            action: #selector(toggleRemoteAccess(_:)),
            keyEquivalent: ""
        )
        remoteAccessItem.target = self
        remoteAccessItem.state = remoteAccessController.isEnabled ? .on : .off
        remoteAccessMenuItem = remoteAccessItem
        let defaultTerminalItem = appMenu.addItem(
            withTitle: "Make Portal System Default Terminal",
            action: #selector(toggleDefaultTerminal(_:)),
            keyEquivalent: ""
        )
        defaultTerminalItem.target = self
        defaultTerminalMenuItem = defaultTerminalItem
        updateDefaultTerminalMenuItem()
        appMenu.addItem(.separator())

        appMenu.addItem(
            withTitle: "Hide \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        appItem.submenu = appMenu
        appMenu.delegate = self
        return appItem
    }

    @objc private func toggleRemoteAccess(_ sender: NSMenuItem) {
        let enabled = !remoteAccessController.isEnabled
        remoteAccessController.setEnabled(enabled)
        sender.state = enabled ? .on : .off
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === defaultTerminalMenuItem?.menu {
            updateDefaultTerminalMenuItem()
        } else if menu === remoteTabsMenu {
            populateRemoteTabsMenu(menu)
        }
    }

    @objc private func toggleDefaultTerminal(_ sender: NSMenuItem) {
        let makeDefault = !isDefaultTerminal
        sender.isEnabled = false

        if makeDefault {
            rememberCurrentTerminalHandlers()
        }

        Task { @MainActor in
            do {
                let handlerURLs = makeDefault
                    ? Array(repeating: Bundle.main.bundleURL, count: Self.terminalContentTypes.count)
                    : previousTerminalHandlerURLs()
                for (contentType, handlerURL) in zip(Self.terminalContentTypes, handlerURLs) {
                    try await NSWorkspace.shared.setDefaultApplication(at: handlerURL, toOpen: contentType)
                }
                if !makeDefault {
                    UserDefaults.standard.removeObject(forKey: Self.previousTerminalHandlersDefaultsKey)
                }
            } catch {
                presentDefaultTerminalError(error)
            }
            sender.isEnabled = true
            updateDefaultTerminalMenuItem()
        }
    }

    private var isDefaultTerminal: Bool {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        return Self.terminalContentTypes.allSatisfy {
            NSWorkspace.shared.urlForApplication(toOpen: $0)?.standardizedFileURL == bundleURL
        }
    }

    private func updateDefaultTerminalMenuItem() {
        defaultTerminalMenuItem?.state = isDefaultTerminal ? .on : .off
    }

    private func rememberCurrentTerminalHandlers() {
        let urls = Self.terminalContentTypes.map {
            NSWorkspace.shared.urlForApplication(toOpen: $0)?.absoluteString ?? ""
        }
        UserDefaults.standard.set(urls, forKey: Self.previousTerminalHandlersDefaultsKey)
    }

    private func previousTerminalHandlerURLs() -> [URL] {
        let storedURLs = UserDefaults.standard.stringArray(
            forKey: Self.previousTerminalHandlersDefaultsKey
        ) ?? []
        let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        return Self.terminalContentTypes.indices.map { index in
            storedURLs.indices.contains(index) ? URL(string: storedURLs[index]) ?? terminalURL : terminalURL
        }
    }

    private func presentDefaultTerminalError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "Could not change the default terminal"
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc private func selectBackgroundBlurEffect(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let effect = BackgroundBlurEffect(rawValue: rawValue)
        else { return }

        UserDefaults.standard.set(effect.rawValue, forKey: BackgroundBlurEffect.defaultsKey)
        controller?.backgroundBlurEffect = effect
        sender.menu?.items.forEach { item in
            item.state = item.representedObject as? String == effect.rawValue ? .on : .off
        }
    }

    private func makeTabsMenuItem() -> NSMenuItem {
        let tabsItem = NSMenuItem()
        let tabsMenu = NSMenu(title: "Tabs")

        let newTabItem = tabsMenu.addItem(
            withTitle: "New Tab",
            action: #selector(newTab(_:)),
            keyEquivalent: "t"
        )
        newTabItem.target = self

        let newRemoteTabItem = NSMenuItem(title: "New Remote Tab", action: nil, keyEquivalent: "")
        let remoteTabsMenu = NSMenu(title: "New Remote Tab")
        remoteTabsMenu.delegate = self
        newRemoteTabItem.submenu = remoteTabsMenu
        tabsMenu.addItem(newRemoteTabItem)
        self.remoteTabsMenu = remoteTabsMenu
        populateRemoteTabsMenu(remoteTabsMenu)

        let reopenClosedTabItem = tabsMenu.addItem(
            withTitle: "Reopen Closed Tab",
            action: #selector(reopenClosedTab(_:)),
            keyEquivalent: "T"
        )
        reopenClosedTabItem.keyEquivalentModifierMask = [.command, .shift]
        reopenClosedTabItem.target = self
        tabsMenu.addItem(.separator())

        let previousTabItem = tabsMenu.addItem(
            withTitle: "Select Previous Tab",
            action: #selector(selectPreviousTab(_:)),
            keyEquivalent: "["
        )
        previousTabItem.keyEquivalentModifierMask = [.command, .shift]
        previousTabItem.target = self

        let nextTabItem = tabsMenu.addItem(
            withTitle: "Select Next Tab",
            action: #selector(selectNextTab(_:)),
            keyEquivalent: "]"
        )
        nextTabItem.keyEquivalentModifierMask = [.command, .shift]
        nextTabItem.target = self
        tabsMenu.addItem(.separator())

        let killClosedTabsItem = tabsMenu.addItem(
            withTitle: "Exit Closed Tabs...",
            action: #selector(killClosedTabs(_:)),
            keyEquivalent: ""
        )
        killClosedTabsItem.target = self

        tabsItem.submenu = tabsMenu
        return tabsItem
    }

    private func populateRemoteTabsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let loadingItem = menu.addItem(withTitle: "Loading...", action: nil, keyEquivalent: "")
        loadingItem.isEnabled = false

        Task { [weak self, weak menu] in
            guard let self,
                  let menu,
                  menu === remoteTabsMenu
            else { return }
            let macs = await controller?.availableRelayMacs() ?? []
            menu.removeAllItems()
            if macs.isEmpty {
                let emptyItem = menu.addItem(withTitle: "No Macs Online", action: nil, keyEquivalent: "")
                emptyItem.isEnabled = false
                return
            }
            for mac in macs.sorted(by: {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }) {
                let item = menu.addItem(
                    withTitle: mac.name,
                    action: #selector(newRelayTab(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = mac
            }
        }
    }

    private func makeEditMenuItem() -> NSMenuItem {
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")

        editMenu.addItem(
            withTitle: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        let redoItem = editMenu.addItem(
            withTitle: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(
            withTitle: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editMenu.addItem(.separator())
        let findItem = NSMenuItem()
        findItem.title = "Find"
        let findMenu = NSMenu(title: "Find")
        let findInHistoryItem = findMenu.addItem(
            withTitle: "Find...",
            action: #selector(findInHistory(_:)),
            keyEquivalent: "f"
        )
        findInHistoryItem.target = self
        let findNextItem = findMenu.addItem(
            withTitle: "Find Next",
            action: #selector(findNextInHistory(_:)),
            keyEquivalent: "g"
        )
        findNextItem.target = self
        let findPreviousItem = findMenu.addItem(
            withTitle: "Find Previous",
            action: #selector(findPreviousInHistory(_:)),
            keyEquivalent: "g"
        )
        findPreviousItem.keyEquivalentModifierMask = [.command, .shift]
        findPreviousItem.target = self
        findItem.submenu = findMenu
        editMenu.addItem(findItem)
        editMenu.addItem(.separator())
        let clearItem = editMenu.addItem(
            withTitle: "Clear Tab",
            action: #selector(clearActiveTab(_:)),
            keyEquivalent: "k"
        )
        clearItem.target = self
        let clearHistoryItem = editMenu.addItem(
            withTitle: "Clear Command History...",
            action: #selector(clearCommandHistory(_:)),
            keyEquivalent: ""
        )
        clearHistoryItem.target = self

        editItem.submenu = editMenu
        return editItem
    }

    private func makeWindowMenuItem() -> NSMenuItem {
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")

        let closeItem = windowMenu.addItem(
            withTitle: "Close",
            action: #selector(closeActiveTabOrWindow(_:)),
            keyEquivalent: "w"
        )
        closeItem.target = self
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )

        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        return windowItem
    }
}

private extension NSToolbar.Identifier {
    static let vaulttyTitlebar = NSToolbar.Identifier("com.automicvault.vaultty.titlebar")
}

@main
private enum VaulttyApplication {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.appearance = NSAppearance(named: .darkAqua)
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

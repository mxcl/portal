import AppKit
import AppUpdater
import Carbon.HIToolbox
import ServiceManagement
import UniformTypeIdentifiers

private let launcherHotKeySignature = OSType(0x5052544C) // PRTL
private let launcherHotKeyID = UInt32(1)

private enum LauncherHotKey: String, CaseIterable {
    case functionGrave
    case optionSpace
    case commandSpace

    static let defaultsKey = "launcherHotKey"
    private static let didMigrateFunctionGraveDefaultKey = "didMigrateFunctionGraveDefault"

    static var preferred: LauncherHotKey {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: didMigrateFunctionGraveDefaultKey) {
            defaults.set(true, forKey: didMigrateFunctionGraveDefaultKey)
            if defaults.string(forKey: defaultsKey) == optionSpace.rawValue {
                defaults.removeObject(forKey: defaultsKey)
            }
        }
        return defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .functionGrave
    }

    var title: String {
        switch self {
        case .functionGrave: "fn `"
        case .optionSpace: "⌥ Space"
        case .commandSpace: "⌘ Space"
        }
    }

    var carbonKeyCode: UInt32 {
        switch self {
        case .functionGrave: UInt32(kVK_ANSI_Grave)
        case .optionSpace, .commandSpace: UInt32(kVK_Space)
        }
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .functionGrave: UInt32(kEventKeyModifierFnMask)
        case .optionSpace: UInt32(optionKey)
        case .commandSpace: UInt32(cmdKey)
        }
    }
}

private enum AppWindowMetrics {
    static let defaultContentSize = NSSize(width: 1120, height: 760)
    static let minimumContentSize = NSSize(width: 760, height: 480)
    static let launcherWidth: CGFloat = 720
    static let launcherHeight: CGFloat = 420
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, NSMenuDelegate {
    private static let terminalContentTypes = [
        UTType.unixExecutable,
        UTType(importedAs: "com.apple.terminal.shell-script")
    ]
    private static let previousTerminalHandlersDefaultsKey = "previousTerminalHandlerURLs"
    private let updater = AppUpdater(owner: "mxcl", repo: "portal")
    private var window: NSWindow?
    private var controller: TerminalViewController?
    private var launcherController: LauncherViewController?
    private weak var displayedController: NSViewController?
    private var terminalFrame: NSRect?
    private var titleToolbar: NSToolbar?
    private var pendingOpenURLs: [URL] = []
    private var stagedUpdate: Update?
    private var updateCheckTask: Task<Void, Never>?
    private var isInstallingUpdate = false
    private weak var defaultTerminalMenuItem: NSMenuItem?
    private weak var remoteAccessMenuItem: NSMenuItem?
    private weak var remoteTabsMenu: NSMenu?
    private weak var hotKeyMenu: NSMenu?
    private weak var launchAtLoginMenuItem: NSMenuItem?
    private let remoteAccessController = MacRemoteAccessController()
    private var registeredHotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        guard prepareSessionService() else {
            NSApp.terminate(nil)
            return
        }

        let args = ProcessInfo.processInfo.arguments
        let selfTestCommand = args.enumerated().first { $0.element == "--self-test" }
            .flatMap { index, _ in args.indices.contains(index + 1) ? args[index + 1] : nil }
        let initialController: NSViewController
        if selfTestCommand != nil {
            let controller = makeTerminalController(
                selfTestCommand: selfTestCommand,
                restoresPersistedWindow: true
            )
            self.controller = controller
            initialController = controller
        } else {
            let launcher = makeLauncherController()
            launcherController = launcher
            initialController = launcher
        }
        initialController.loadViewIfNeeded()

        let styleMask: NSWindow.StyleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
            .fullSizeContentView
        ]
        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: selfTestCommand == nil
                    ? NSSize(width: AppWindowMetrics.launcherWidth, height: AppWindowMetrics.launcherHeight)
                    : AppWindowMetrics.defaultContentSize
            ),
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
        window.tabbingMode = .disallowed
        window.isMovableByWindowBackground = false
        window.delegate = self
        let toolbar = NSToolbar(identifier: .portalTitlebar)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        titleToolbar = toolbar
        self.window = window
        display(initialController, asLauncher: selfTestCommand == nil)
        if selfTestCommand == nil {
            installHotKeyHandler()
            _ = registerHotKey(LauncherHotKey.preferred, reportsError: false)
            configureLaunchAtLogin()
        }
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        NSApp.activate(ignoringOtherApps: true)
        controller?.windowDidAttach()
        openPendingURLs()
        if selfTestCommand == nil {
            checkForUpdates()
            remoteAccessController.startIfEnabled()
        }
    }

    private func makeTerminalController(
        selfTestCommand: String? = nil,
        restoresPersistedWindow: Bool
    ) -> TerminalViewController {
        let controller = TerminalViewController(
            selfTestCommand: selfTestCommand,
            restoresPersistedWindow: restoresPersistedWindow,
            showsTabStrip: false
        )
        controller.onInstallStagedUpdate = { [weak self] in
            self?.confirmInstallStagedUpdate()
        }
        controller.onShowLauncher = { [weak self] in
            self?.showLauncher()
        }
        controller.remoteAccessEnabled = remoteAccessController.isEnabled
        controller.onSetRemoteAccessEnabled = { [weak self] enabled in
            self?.setRemoteAccessEnabled(enabled) ?? false
        }
        controller.loadViewIfNeeded()
        return controller
    }

    private func makeLauncherController() -> LauncherViewController {
        let launcher = LauncherViewController()
        launcher.onRunCommand = { [weak self] command in
            self?.openTerminal(running: command)
        }
        launcher.onOpenSession = { [weak self] candidate in
            self?.openTerminal(session: candidate)
        }
        launcher.onLaunchApplication = { [weak self] suggestion in
            self?.launchApplication(suggestion)
        }
        launcher.onCancel = { [weak self] in
            self?.hideWindow()
        }
        launcher.onHeightChanged = { [weak self] height in
            self?.resizeLauncher(to: height)
        }
        return launcher
    }

    fileprivate func toggleLauncher() {
        guard let window else { return }
        if displayedController === launcherController, window.isVisible {
            hideWindow()
            return
        }
        showLauncher()
    }

    private func showLauncher() {
        guard let window else { return }
        discardTerminalController()
        let launcher = launcherController ?? makeLauncherController()
        launcherController = launcher
        launcher.loadViewIfNeeded()
        launcher.reset()
        display(launcher, asLauncher: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func discardTerminalController() {
        guard let controller else { return }
        if displayedController === controller {
            terminalFrame = window?.frame
            controller.view.removeFromSuperview()
            displayedController = nil
        }
        controller.stopAllSessions()
        self.controller = nil
    }

    private func hideWindow() {
        if displayedController === launcherController {
            launcherController?.suspend()
        }
        window?.orderOut(nil)
    }

    private func openTerminal(running command: String) {
        replaceTerminalController()
        guard let controller else { return }
        display(controller, asLauncher: false)
        controller.runFromLauncher(command)
        controller.windowDidAttach()
    }

    private func openTerminal(session candidate: SessionPickerCandidate) {
        if controller?.activeSessionRef == candidate.sessionRef, let controller {
            display(controller, asLauncher: false)
            controller.windowDidAttach()
            return
        }
        replaceTerminalController()
        guard let controller else { return }
        controller.openFromLauncher(candidate)
        display(controller, asLauncher: false)
        controller.windowDidAttach()
    }

    private func replaceTerminalController() {
        controller?.stopAllSessions()
        let replacement = makeTerminalController(restoresPersistedWindow: false)
        controller = replacement
    }

    private func display(_ controller: NSViewController, asLauncher: Bool) {
        guard let window, let contentView = window.contentView else { return }
        if displayedController === self.controller {
            terminalFrame = window.frame
        }
        if displayedController === launcherController, controller !== launcherController {
            launcherController?.suspend()
        }
        displayedController?.view.removeFromSuperview()
        controller.view.frame = contentView.bounds
        controller.view.autoresizingMask = [.width, .height]
        contentView.addSubview(controller.view)
        displayedController = controller

        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        if asLauncher {
            terminalFrame = terminalFrame ?? window.frame
            window.styleMask.remove([.resizable, .miniaturizable])
            window.level = .floating
            resizeLauncher(
                to: max(AppWindowMetrics.launcherHeight, controller.view.fittingSize.height),
                repositions: true
            )
        } else {
            window.styleMask.insert([.resizable, .miniaturizable])
            window.level = .normal
            window.contentMinSize = AppWindowMetrics.minimumContentSize
            window.setFrame(terminalFrame ?? NSRect(origin: window.frame.origin, size: AppWindowMetrics.defaultContentSize), display: true, animate: true)
        }
    }

    private func resizeLauncher(to height: CGFloat, repositions: Bool = false) {
        guard let window, displayedController === launcherController else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? window.screen
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let contentHeight = min(max(108, height), visibleFrame.height * 0.82)
        let contentRect = NSRect(
            x: visibleFrame.midX - AppWindowMetrics.launcherWidth / 2,
            y: visibleFrame.maxY - contentHeight - visibleFrame.height * 0.18,
            width: AppWindowMetrics.launcherWidth,
            height: contentHeight
        )
        var frame = NSWindow.frameRect(forContentRect: contentRect, styleMask: window.styleMask)
        if !repositions {
            frame.origin = window.frame.origin
        }
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    private func launchApplication(_ suggestion: CompletionSuggestion) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: suggestion.source),
            configuration: configuration
        ) { [weak self] _, error in
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let message {
                    self.launcherController?.showError(message)
                } else {
                    self.hideWindow()
                }
            }
        }
    }

    private func prepareSessionService() -> Bool {
        do {
            switch try PtySession.prepareLocalDaemon() {
            case .ready:
                return true
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
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if displayedController == nil {
            showLauncher()
        } else {
            window?.deminiaturize(nil)
            window?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let registeredHotKey {
            UnregisterEventHotKey(registeredHotKey)
        }
        if let hotKeyHandler {
            RemoveEventHandler(hotKeyHandler)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if displayedController === controller {
            controller?.windowDidBecomeActive()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        if displayedController === controller {
            controller?.windowDidBecomeActive()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === window,
              displayedController === launcherController
        else { return }
        hideWindow()
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        discardTerminalController()
        hideWindow()
        return false
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
        alert.informativeText = "Portal will quit, install \(stagedUpdate.assetName), and relaunch. Shell sessions will keep running during the update."
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
                let preparedUpdate = try await update.prepareInstallation()
                isInstallingUpdate = true
                try await preparedUpdate.installAndRelaunch()
            } catch {
                isInstallingUpdate = false
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
        if controller == nil {
            replaceTerminalController()
        }
        guard let controller else { return }
        display(controller, asLauncher: false)
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

    private func installHotKeyHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var received = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &received
            )
            guard received.signature == launcherHotKeySignature,
                  received.id == launcherHotKeyID
            else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in delegate.toggleLauncher() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        if status != noErr {
            NSLog("Portal could not install its global hot-key handler: \(status)")
        }
    }

    @discardableResult
    private func registerHotKey(_ hotKey: LauncherHotKey, reportsError: Bool) -> Bool {
        if let registeredHotKey {
            UnregisterEventHotKey(registeredHotKey)
            self.registeredHotKey = nil
        }
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: launcherHotKeySignature, id: launcherHotKeyID)
        let status = RegisterEventHotKey(
            hotKey.carbonKeyCode,
            hotKey.carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr else {
            if reportsError {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "\(hotKey.title) is already in use"
                alert.informativeText = "Change the other app’s shortcut, then try again."
                alert.runModal()
            }
            return false
        }
        registeredHotKey = reference
        UserDefaults.standard.set(hotKey.rawValue, forKey: LauncherHotKey.defaultsKey)
        hotKeyMenu?.items.forEach {
            $0.state = $0.representedObject as? String == hotKey.rawValue ? .on : .off
        }
        return true
    }

    private func configureLaunchAtLogin() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "launchAtLogin") == nil {
            defaults.set(true, forKey: "launchAtLogin")
        }
        guard defaults.bool(forKey: "launchAtLogin"), SMAppService.mainApp.status == .notRegistered else {
            return
        }
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("Portal could not enable launch at login: \(error.localizedDescription)")
        }
    }

    @objc private func selectLauncherHotKey(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let hotKey = LauncherHotKey(rawValue: rawValue)
        else { return }
        let previous = LauncherHotKey.preferred
        if !registerHotKey(hotKey, reportsError: true) {
            _ = registerHotKey(previous, reportsError: false)
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                UserDefaults.standard.set(false, forKey: "launchAtLogin")
            } else {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: "launchAtLogin")
            }
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Could not change launch at login"
            alert.runModal()
        }
    }

    private func makeMainMenu() -> NSMenu {
        let menu = NSMenu(title: "Main Menu")
        menu.addItem(makeAppMenuItem())
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
        let hotKeyItem = NSMenuItem(title: "Launcher Hot Key", action: nil, keyEquivalent: "")
        let hotKeyMenu = NSMenu(title: "Launcher Hot Key")
        for hotKey in LauncherHotKey.allCases {
            let item = hotKeyMenu.addItem(
                withTitle: hotKey.title,
                action: #selector(selectLauncherHotKey(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = hotKey.rawValue
            item.state = hotKey == LauncherHotKey.preferred ? .on : .off
        }
        self.hotKeyMenu = hotKeyMenu
        hotKeyItem.submenu = hotKeyMenu
        preferencesMenu.addItem(hotKeyItem)
        let loginItem = preferencesMenu.addItem(
            withTitle: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        launchAtLoginMenuItem = loginItem
        preferencesMenu.addItem(.separator())
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
        setRemoteAccessEnabled(!remoteAccessController.isEnabled)
    }

    @discardableResult
    private func setRemoteAccessEnabled(_ enabled: Bool) -> Bool {
        guard !enabled || ICloudKeychainRootKey.hasActiveICloudAccount() else {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Remote Access Requires iCloud"
            alert.informativeText = "Sign in to your Apple Account in System Settings, then try again."
            if let window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
            return false
        }
        remoteAccessController.setEnabled(enabled)
        remoteAccessMenuItem?.state = enabled ? .on : .off
        controller?.remoteAccessEnabled = enabled
        return true
    }

    func menuWillOpen(_ menu: NSMenu) {
        launchAtLoginMenuItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
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
    static let portalTitlebar = NSToolbar.Identifier("dev.mxcl.portal.titlebar")
}

@main
private enum PortalApplication {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        NSWindow.allowsAutomaticWindowTabbing = false
        let delegate = AppDelegate()
        app.delegate = delegate
        app.appearance = NSAppearance(named: .darkAqua)
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

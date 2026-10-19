#if os(macOS)
import AppKit
import Combine
import ServiceManagement
import SwiftUI
import PortalEngine

@main
@MainActor
struct PortalMenuBarApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = MenuAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
private final class MenuBarIcon {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let badge = MenuBarBadge(frame: .zero)

    init() {
        guard let button = statusItem.button else { return }
        badge.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 6),
            badge.heightAnchor.constraint(equalToConstant: 6),
            badge.trailingAnchor.constraint(equalTo: button.centerXAnchor, constant: 8),
            badge.topAnchor.constraint(equalTo: button.centerYAnchor, constant: -10),
        ])
    }

    func update(isPaused: Bool, hasUnreadNotifications: Bool) {
        statusItem.button?.image = Self.image(isPaused: isPaused)
        badge.isHidden = !hasUnreadNotifications
        statusItem.button?.setAccessibilityLabel(hasUnreadNotifications
            ? "Portal, unread GitHub notifications" : "Portal")
    }

    private static let sessionIcon: NSImage = {
        guard let url = Bundle.main.url(forResource: "session-icon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "terminal", accessibilityDescription: "Portal")!
        }
        return image
    }()

    private static func image(isPaused: Bool) -> NSImage {
        // Keep the icon templated; the separate badge retains its own color.
        let renderer = ImageRenderer(content:
            Image(nsImage: Self.sessionIcon)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(.black)
                .shadow(color: .black, radius: 0, x: 0.3)
                .shadow(color: .black, radius: 0, x: -0.3)
                .opacity(isPaused ? 0.45 : 1)
                .frame(width: 16, height: 20)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }
}

private final class MenuBarBadge: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

@MainActor
final class MenuBarRuntime: ObservableObject {
    let model: EngineModel
    private let github: GitHubController
    private let server: EngineControlServer?
    private var observation: AnyCancellable?
    private var appNotificationPending = false
    private var lastAppSnapshot: EngineSnapshot?
    private var terminationObservation: AnyCancellable?
    private let shortcut = GlobalShortcut()
    private var shortcutObservation: AnyCancellable?

    init() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "migrated-portal-helper-preferences") && !defaults.bool(forKey: "migrated-gitinuum-helper-preferences") {
            if let previous = defaults.persistentDomain(forName: "dev.mxcl.git-sync.menu-helper") {
                for (key, value) in previous { defaults.set(value, forKey: key) }
            }
            defaults.set(true, forKey: "migrated-portal-helper-preferences")
        }
        model = EngineModel(executableURL: Self.gitSyncExecutableURL)
        github = GitHubController(model: model)
        MenuAppDelegate.github = github
        server = try? EngineControlServer()
        server?.start(model: model)
        shortcutObservation = model.$globalShortcutEnabled.removeDuplicates().sink { [weak self] enabled in
            guard let self else { return }
            do {
                try shortcut.setEnabled(enabled)
                model.globalShortcutError = nil
            } catch {
                model.globalShortcutError = error.localizedDescription
            }
        }
        observation = model.objectWillChange.sink { [weak self] in
            // Rebuilding a tracked menu dismisses its open submenus. Catch up after it closes.
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            }
            guard let self, !self.appNotificationPending else { return }
            self.appNotificationPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                self.appNotificationPending = false
                var snapshot = self.model.snapshot()
                snapshot.logs = [] // Menu logs do not change the project window.
                guard snapshot != self.lastAppSnapshot else { return }
                self.lastAppSnapshot = snapshot
                DistributedNotificationCenter.default().postNotificationName(
                    EngineControlProtocol.changedNotification,
                    object: nil,
                    deliverImmediately: true
                )
            }
        }
        terminationObservation = NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.github.shutdown(); self?.model.shutdown() }
    }

    func menuOpened() async {
        github.menuOpened()
        await model.refreshProjectStatuses()
    }

    func quitEverything() {
        github.shutdown()
        model.shutdown()
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "dev.mxcl.portal") {
            app.terminate()
        }
        server?.stop()
        NSApplication.shared.terminate(nil)
    }

    private static var outerApplicationURL: URL {
        Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var gitSyncExecutableURL: URL {
        outerApplicationURL.appendingPathComponent("Contents/Resources/portald")
    }

    static func openMainApplication(showPalette: Bool = false) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        if showPalette {
            NSWorkspace.shared.open([URL(string: "portal://palette")!], withApplicationAt: outerApplicationURL,
                                    configuration: configuration)
        } else {
            NSWorkspace.shared.openApplication(at: outerApplicationURL, configuration: configuration)
        }
    }
}

@MainActor
final class MenuAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var runtime: MenuBarRuntime?
    private var icon: MenuBarIcon?
    private var observation: AnyCancellable?
    static weak var github: GitHubController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let runtime = MenuBarRuntime()
        let icon = MenuBarIcon()
        self.runtime = runtime
        self.icon = icon
        let menu = NSHostingMenu(rootView: StatusMenu(runtime: runtime))
        menu.delegate = self
        icon.statusItem.menu = menu
        updateIcon()
        observation = runtime.objectWillChange.sink { [weak self] in
            self?.updateIcon()
        }
        NSApplication.shared.registerForRemoteNotifications()
    }
    private func updateIcon() {
        guard let runtime else { return }
        icon?.update(isPaused: runtime.model.isPaused,
                     hasUnreadNotifications: runtime.model.github.showsUnreadNotifications)
    }
    func menuWillOpen(_ menu: NSMenu) {
        Task { await runtime?.menuOpened() }
    }
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.github?.registered(token: deviceToken)
    }
    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Self.github?.registrationFailed(error)
    }
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        if userInfo["portalWork"] as? Bool == true || userInfo["gitinuumWork"] as? Bool == true { Self.github?.receivedPush() }
    }
}

private struct StatusMenu: View {
    @ObservedObject var runtime: MenuBarRuntime

    var body: some View {
        Text(runtime.model.status)
        if let error = runtime.model.globalShortcutError { Text(error) }
        Divider()
        Section("Project Status") {
            if runtime.model.localProjects.isEmpty {
                Text("No local repositories")
            }
            ForEach(runtime.model.localProjects.keys.sorted(), id: \.self) { name in
                Button {
                    var url = URLComponents()
                    url.scheme = "portal"
                    url.host = "project"
                    url.queryItems = [URLQueryItem(name: "name", value: name)]
                    if let url = url.url { NSWorkspace.shared.open(url) }
                } label: {
                    let status = Text(runtime.model.projectStatuses[name] ?? "Checking…")
                        .foregroundColor(Color(nsColor: .disabledControlTextColor))
                    Text("\(name): \(status)")
                }
            }
        }
        let notifications = Dictionary(grouping: runtime.model.github.unreadNotifications.prefix(20), by: \.repository)
        if notifications.isEmpty { Text("No unread notifications") }
        ForEach(notifications.keys.sorted(), id: \.self) { repository in
            Section(repository) {
                ForEach(notifications[repository] ?? []) { note in
                    Button {
                        if let url = note.safeURL, NSWorkspace.shared.open(url) {
                            Task { await runtime.model.githubAction?(.notificationOpened(id: note.id)) }
                        }
                    } label: {
                        Label(note.title, systemImage: note.menuSymbol)
                    }
                    .help(note.body)
                }
            }
        }
        Divider()
        Menu("Events") {
            if runtime.model.menuLogs.isEmpty {
                Text("No events yet")
            } else {
                ForEach(Array(runtime.model.menuLogs.enumerated()), id: \.offset) { Text($0.element) }
            }
        }
        Button(runtime.model.isPaused ? "Resume Sync" : "Pause Sync") {
            runtime.model.isPaused ? runtime.model.resume() : runtime.model.pause()
        }
        .disabled(!runtime.model.isConfigured)
        Divider()
        Button("Open Portal") {
            MenuBarRuntime.openMainApplication()
        }
        .keyboardShortcut(runtime.model.globalShortcutEnabled
                          ? KeyboardShortcut("`", modifiers: [.command, .option]) : nil)
        if SMAppService.loginItem(identifier: "dev.mxcl.portal.menu-helper").status == .requiresApproval {
            Button("Login Items…") { SMAppService.openSystemSettingsLoginItems() }
        }
        Divider()
        Button("Quit", action: runtime.quitEverything)
    }
}

private extension GitHubNotification {
    var menuSymbol: String {
        // GitHub browser URLs start with /owner/repository/subject-kind.
        switch safeURL?.pathComponents.dropFirst(3).first {
        case "issues": "exclamationmark.circle"
        case "pull": "arrow.triangle.pull"
        case "discussions": "bubble.left.and.bubble.right"
        case "releases": "tag"
        case "commit": "point.3.connected.trianglepath.dotted"
        case "actions": "play.circle"
        case "security": "shield.lefthalf.filled"
        default: "bell"
        }
    }
}
#else
import Foundation
@main enum PortalMenuBarApp { static func main() { print("Portal Menu Helper is available on macOS only") } }
#endif

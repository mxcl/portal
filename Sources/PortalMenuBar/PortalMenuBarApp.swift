#if os(macOS)
import AppKit
import Combine
import ServiceManagement
import SwiftUI
import PortalEngine

@main
struct PortalMenuBarApp: App {
    @NSApplicationDelegateAdaptor(MenuAppDelegate.self) private var appDelegate
    @StateObject private var runtime = MenuBarRuntime()

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(runtime: runtime)
                .task { await runtime.menuOpened() }
        } label: {
            MenuBarIcon(isPaused: runtime.model.isPaused,
                        hasUnreadNotifications: runtime.model.github.showsUnreadNotifications)
        }
    }
}

private struct MenuBarIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    let isPaused: Bool
    let hasUnreadNotifications: Bool

    private static let sessionIcon: NSImage = {
        guard let url = Bundle.main.url(forResource: "session-icon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "terminal", accessibilityDescription: "Portal")!
        }
        return image
    }()

    var body: some View {
        // MenuBarExtra extracts an image from its label, so bake the colored badge into it.
        let renderer = ImageRenderer(content:
            Image(nsImage: Self.sessionIcon)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(colorScheme == .dark ? .white : .black)
                .shadow(color: colorScheme == .dark ? .white : .black, radius: 0, x: 0.3)
                .shadow(color: colorScheme == .dark ? .white : .black, radius: 0, x: -0.3)
                .opacity(isPaused ? 0.45 : 1)
                .frame(width: 16, height: 20)
                .overlay(alignment: .topTrailing) {
                    if hasUnreadNotifications {
                        Circle().fill(.blue).frame(width: 6, height: 6)
                    }
                }
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return Image(nsImage: renderer.nsImage ?? NSImage())
            .renderingMode(.original)
            .accessibilityLabel(hasUnreadNotifications
                ? "Portal, unread GitHub notifications" : "Portal")
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

    static func openMainApplication() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: outerApplicationURL, configuration: configuration)
    }
}

@MainActor
final class MenuAppDelegate: NSObject, NSApplicationDelegate {
    static weak var github: GitHubController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
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
                    Button(note.title) {
                        if let url = note.safeURL, NSWorkspace.shared.open(url) {
                            Task { await runtime.model.githubAction?(.notificationOpened(id: note.id)) }
                        }
                    }.help(note.body)
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
#else
import Foundation
@main enum PortalMenuBarApp { static func main() { print("Portal Menu Helper is available on macOS only") } }
#endif

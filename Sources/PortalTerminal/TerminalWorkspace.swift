#if os(macOS)
import AppKit
import CryptoKit
import Combine
import SwiftUI

/// SSH uses the user's normal configuration, agent, and known_hosts database.
public struct TerminalHost: Equatable, Sendable {
    public let id: String
    public let name: String
    public let peer: String
    public let helperPath: String
    public let directory: String

    public init(id: String, name: String, peer: String, helperPath: String, directory: String) {
        self.id = id
        self.name = name
        self.peer = peer
        self.helperPath = helperPath
        self.directory = directory
    }
}

/// Owns project terminals for the lifetime of the app, including while another pane is visible.
@MainActor
public final class TerminalWorkspace: ObservableObject {
    public enum Activity { case running, unviewed }
    @Published public private(set) var projectActivities: [String: Activity] = [:]
    private var controllerProjects: [String: String] = [:]

    private func refreshProjectActivity(_ project: String) {
        let activities = controllers.compactMap { key, controller in
            controllerProjects[key] == project ? controller.projectActivity : nil
        }
        projectActivities[project] = activities.contains(.running) ? .running : activities.first
    }

    private var controllers: [String: TerminalViewController] = [:]
    private var activeController: TerminalViewController?
    private var windows: [NSWindow] = []

    @Published fileprivate var standaloneFocused = false
    private var focusObserver: AnyCancellable?

    public init() {
        focusObserver = NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification))
            .sink { [weak self] notification in
                if let controller = self?.activeController, controller.isViewLoaded,
                   let window = notification.object as? NSWindow, controller.view.window === window {
                    if notification.name == NSWindow.didBecomeKeyNotification {
                        controller.windowDidBecomeActive()
                    }
                }
                self?.standaloneFocused = (NSApp.keyWindow?.contentViewController as? TerminalViewController)?.standalone == true
            }
    }

    public func newWindow(directory: URL = FileManager.default.homeDirectoryForCurrentUser, command: String? = nil, hosts: [TerminalHost]? = nil) {
        if let hosts { PtySession.configureSSHHosts(hosts) }
        let controller = TerminalViewController(restoresPersistedWindow: false, initialDirectory: directory, standalone: true, launchCommand: command, sessionHosts: hosts ?? [])
        let window = StandaloneTerminalWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.delegate = window
        window.title = "Terminal"
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let toolbar = NSToolbar(identifier: "dev.mxcl.portal.terminal.titlebar")
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        window.contentViewController = controller
        window.contentMinSize = NSSize(width: 760, height: 480)
        window.setContentSize(NSSize(width: 1120, height: 760))
        windows.removeAll { !$0.isVisible }
        windows.append(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func view(project: String, directory: URL, hosts: [TerminalHost], host: TerminalHost? = nil) -> some View {
        GeometryReader { geometry in
            EmbeddedTerminal(workspace: self, project: project, directory: directory, hosts: hosts, host: host,
                             toolbarInset: geometry.safeAreaInsets.top)
                .background(.background)
                .ignoresSafeArea(.container, edges: .top)
        }
        .id((host?.id ?? "local") + directory.path)
    }

    fileprivate func controller(project: String, directory: URL, hosts: [TerminalHost], host: TerminalHost?) -> TerminalViewController {
        PtySession.configureSSHHosts(hosts)
        let path = (host?.id ?? "local") + ":" + directory.standardizedFileURL.path
        if let controller = controllers[path] {
            activeController = controller
            return controller
        }
        let key = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        let controller = TerminalViewController(windowID: key, restoresPersistedWindow: false,
                                                initialDirectory: directory, initialHostID: host?.id, sessionHosts: hosts)
        controllerProjects[path] = project
        controller.onActivityChange = { [weak self] in self?.refreshProjectActivity(project) }
        controllers[path] = controller
        activeController = controller
        return controller
    }

    fileprivate func connect(_ host: TerminalHost) {
        activeController?.newSSHSession(host)
    }

    fileprivate func perform(_ action: Selector) {
        guard let controller = (NSApp.keyWindow?.contentViewController as? TerminalViewController) ?? activeController else { return }
        NSApp.sendAction(action, to: controller, from: nil)
    }
}

final class StandaloneTerminalWindow: NSWindow, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        (contentViewController as? TerminalViewController)?.stopAllSessions()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        (contentViewController as? TerminalViewController)?.windowDidBecomeActive()
    }
}

private struct EmbeddedTerminal: NSViewControllerRepresentable {
    let workspace: TerminalWorkspace
    let project: String
    let directory: URL
    let hosts: [TerminalHost]
    let host: TerminalHost?
    let toolbarInset: CGFloat

    func makeNSViewController(context: Context) -> NSViewController {
        let controller = workspace.controller(project: project, directory: directory, hosts: hosts, host: host)
        controller.toolbarInset = toolbarInset
        return controller
    }

    func updateNSViewController(_ controller: NSViewController, context: Context) {
        PtySession.configureSSHHosts(hosts)
        (controller as? TerminalViewController)?.toolbarInset = toolbarInset
    }
}

public struct TerminalCommands: Commands {
    @ObservedObject private var workspace: TerminalWorkspace
    let enabled: Bool
    let hosts: [TerminalHost]

    public init(workspace: TerminalWorkspace, enabled: Bool, hosts: [TerminalHost] = []) {
        self.workspace = workspace
        self.enabled = enabled
        self.hosts = hosts
    }

    private var standalone: Bool { workspace.standaloneFocused }

    public var body: some Commands {
        CommandMenu("Terminal") {
            Button("New Terminal Tab") { workspace.perform(#selector(TerminalViewController.newTab(_:))) }
                .disabled(!enabled || standalone)
            Button(standalone ? "Close Terminal Window" : "Close Terminal Tab") { workspace.perform(#selector(TerminalViewController.closeActiveTabOrWindow(_:))) }
                .keyboardShortcut("w", modifiers: [.command, .shift]).disabled(!enabled && !standalone)
            Menu("New SSH Terminal") {
                ForEach(hosts, id: \.id) { host in
                    Button(host.name) { workspace.connect(host) }
                }
            }.disabled(!enabled || standalone || hosts.isEmpty)
            Button("Reopen Closed Terminal Tab") { workspace.perform(#selector(TerminalViewController.reopenClosedTab(_:))) }
                .keyboardShortcut("t", modifiers: [.command, .shift]).disabled(!enabled || standalone)
            Button("Exit Terminal Session…") { workspace.perform(#selector(TerminalViewController.exitActiveSession(_:))) }
                .disabled(!enabled && !standalone)
            Divider()
            Button("Find in Terminal History…") { workspace.perform(#selector(TerminalViewController.findInHistory(_:))) }
                .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(!enabled && !standalone)
            Button("Clear Terminal") { workspace.perform(#selector(TerminalViewController.clearActiveTab(_:))) }
                .keyboardShortcut("k").disabled(!enabled && !standalone)
            Button("Clear Command History…") { workspace.perform(#selector(TerminalViewController.clearCommandHistory(_:))) }
                .disabled(!enabled && !standalone)
        }
    }
}

#endif

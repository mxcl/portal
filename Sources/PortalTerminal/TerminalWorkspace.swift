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
    public enum TerminalState { case active, waiting }
    @Published public private(set) var projectTerminalStates: [String: TerminalState] = [:]
    @Published public private(set) var projectOutputAt: [String: Date] = [:]

    func recordProjectOutput(_ project: String, at date: Date = Date()) {
        // Coalesce busy streams; the sidebar needs a visible pulse, not every byte.
        if let previous = projectOutputAt[project], date.timeIntervalSince(previous) < 0.2 { return }
        projectOutputAt[project] = date
    }

    private var controllerProjects: [String: String] = [:]

    private func refreshProjectActivity(_ project: String) {
        let activities = controllers.compactMap { key, controller in
            controllerProjects[key] == project ? controller.projectActivity : nil
        }
        projectActivities[project] = activities.contains(.running) ? .running : activities.first
        let states = controllers.compactMap { key, controller in
            controllerProjects[key] == project ? controller.projectTerminalState : nil
        }
        projectTerminalStates[project] = states.contains(.active) ? .active : states.first
    }

    private var controllers: [String: TerminalViewController] = [:]
    private var activeController: TerminalViewController?
    private var windows: [NSWindow] = []
    private struct ClosedWindow {
        let session: SessionCatalog.Record?
        let directory: URL
        let hostID: String?
        let hosts: [TerminalHost]
    }
    private var closedWindows: [ClosedWindow] = []
    @Published public private(set) var canReopenClosedTab = false
    public var focusedWindow: NSWindow? { NSApp.keyWindow as? StandaloneTerminalWindow }


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

    public func newWindow(directory: URL = FileManager.default.homeDirectoryForCurrentUser, command: String? = nil, hosts: [TerminalHost] = [], hostID: String? = nil) {
        openWindow(directory: directory, command: command, hosts: hosts, hostID: hostID)
    }

    public func newTab() {
        guard let parent = focusedWindow else { return }
        newTab(in: parent)
    }

    func newTab(in parent: NSWindow) {
        guard let controller = parent.contentViewController as? TerminalViewController else { return }
        openWindow(directory: FileManager.default.homeDirectoryForCurrentUser, hosts: controller.windowHosts,
                   hostID: nil, tabbedWith: parent)
    }

    public func reopenClosedTab() { reopenClosedTab(in: focusedWindow) }

    func reopenClosedTab(in parent: NSWindow?) {
        guard let closed = closedWindows.popLast() else { return }
        canReopenClosedTab = !closedWindows.isEmpty
        openWindow(directory: closed.directory, hosts: closed.hosts, hostID: closed.hostID,
                   restoredSession: closed.session, tabbedWith: parent)
    }

    private func openWindow(directory: URL, command: String? = nil, hosts: [TerminalHost], hostID: String?,
                            restoredSession: SessionCatalog.Record? = nil, tabbedWith parent: NSWindow? = nil) {
        PtySession.configureSSHHosts(hosts)
        let controller = TerminalViewController(restoresPersistedWindow: false, initialDirectory: directory,
            initialHostID: hostID, standalone: true, launchCommand: command, sessionHosts: hosts,
            restoredSession: restoredSession)
        let window = StandaloneTerminalWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.delegate = window
        window.onClose = { [weak self, weak controller, weak window] in
            guard let self, let controller else { return }
            closedWindows.append(ClosedWindow(session: controller.windowSessionRecord,
                directory: controller.windowDirectory, hostID: controller.windowHostID, hosts: controller.windowHosts))
            canReopenClosedTab = true
            windows.removeAll { $0 === window }
        }
        window.title = "Terminal"
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // New Window must remain separate even when the system prefers tabs.
        // Explicit New Tab below opts into AppKit's native tab group.
        window.tabbingIdentifier = "dev.mxcl.portal.terminal"
        window.tabbingMode = .disallowed
        window.contentViewController = controller
        window.contentMinSize = NSSize(width: 760, height: 480)
        // Installing the controller sizes the window to its initially unsized view.
        // Apply the launch size after attachment, before centering or native tabbing.
        window.setContentSize(NSSize(width: 1120, height: 760))
        windows.append(window)
        if let parent {
            parent.tabbingMode = .preferred
            window.tabbingMode = .preferred
            parent.addTabbedWindow(window, ordered: .above)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        window.tabbingMode = .automatic
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
        controller.onOutputActivity = { [weak self] in self?.recordProjectOutput(project) }
        controllers[path] = controller
        activeController = controller
        return controller
    }

    fileprivate func perform(_ action: Selector) {
        guard let controller = (NSApp.keyWindow?.contentViewController as? TerminalViewController) ?? activeController else { return }
        NSApp.sendAction(action, to: controller, from: nil)
    }
}

final class StandaloneTerminalWindow: NSWindow, NSWindowDelegate {
    var onClose: (() -> Void)?

    // Cmd-T calls the workspace directly. Advertising newWindowForTab adds AppKit’s + button.

    func windowWillClose(_ notification: Notification) {
        onClose?()
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
    let nextProjectTerminal: (() -> Void)?
    let newWindow: () -> Void
    let newSSHWindow: (TerminalHost) -> Void
    let managesTabs: Bool

    public init(workspace: TerminalWorkspace, enabled: Bool, hosts: [TerminalHost] = [],
                managesTabs: Bool = false, newWindow: @escaping () -> Void,
                newSSHWindow: @escaping (TerminalHost) -> Void,
                nextProjectTerminal: (() -> Void)? = nil) {
        self.workspace = workspace
        self.enabled = enabled
        self.hosts = hosts
        self.managesTabs = managesTabs
        self.newWindow = newWindow
        self.newSSHWindow = newSSHWindow
        self.nextProjectTerminal = nextProjectTerminal
    }

    public var body: some Commands {
        CommandMenu("Terminal") {
            Button("New Terminal Window", action: newWindow).keyboardShortcut("n")
            Menu("New Terminal Session") {
                ForEach(hosts, id: \.id) { host in
                    Button(host.name) { newSSHWindow(host) }
                }
            }.disabled(hosts.isEmpty)
            if managesTabs {
                Button("New Tab") { workspace.newTab() }
                    .keyboardShortcut("t").disabled(!workspace.standaloneFocused)
                Button("Reopen Closed Tab") { workspace.reopenClosedTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(!workspace.canReopenClosedTab)
                Button("Close Tab") { workspace.focusedWindow?.performClose(nil) }
                    .keyboardShortcut("w").disabled(!workspace.standaloneFocused)
                Button("Show Previous Tab") { workspace.focusedWindow?.selectPreviousTab(nil) }
                    .keyboardShortcut("[", modifiers: [.command, .shift]).disabled(!workspace.standaloneFocused)
                Button("Show Next Tab") { workspace.focusedWindow?.selectNextTab(nil) }
                    .keyboardShortcut("]", modifiers: [.command, .shift]).disabled(!workspace.standaloneFocused)
                Button("Move Tab to New Window") { workspace.focusedWindow?.moveTabToNewWindow(nil) }
                    .disabled(!workspace.standaloneFocused)
            }
            Divider()
            if let nextProjectTerminal {
                Button("Next Project Terminal", action: nextProjectTerminal)
                    .keyboardShortcut("t", modifiers: [.command, .option, .shift])

            }
            Button("Find in History…") { workspace.perform(#selector(TerminalViewController.findInHistory(_:))) }
                .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(!enabled)
            Button("Clear Terminal") { workspace.perform(#selector(TerminalViewController.clearActiveTab(_:))) }
                .keyboardShortcut("k").disabled(!enabled)
            Divider()
            Button("Clear Command History…") { workspace.perform(#selector(TerminalViewController.clearCommandHistory(_:))) }
                .disabled(!enabled)
        }
    }
}

#endif

#if os(macOS)
import AppKit
import CryptoKit
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
public final class TerminalWorkspace {
    private var controllers: [String: TerminalViewController] = [:]
    private var activeController: TerminalViewController?

    public init() {}

    public func view(directory: URL, hosts: [TerminalHost], host: TerminalHost? = nil) -> some View {
        GeometryReader { geometry in
            EmbeddedTerminal(workspace: self, directory: directory, hosts: hosts, host: host,
                             toolbarInset: geometry.safeAreaInsets.top)
                .ignoresSafeArea(.container, edges: .top)
        }
        .id((host?.id ?? "local") + directory.path)
    }

    fileprivate func controller(directory: URL, hosts: [TerminalHost], host: TerminalHost?) -> TerminalViewController {
        PtySession.configureSSHHosts(hosts)
        let path = (host?.id ?? "local") + ":" + directory.standardizedFileURL.path
        if let controller = controllers[path] {
            activeController = controller
            return controller
        }
        let key = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        let controller = TerminalViewController(windowID: key, restoresPersistedWindow: false,
                                                initialDirectory: directory, initialHostID: host?.id)
        controllers[path] = controller
        activeController = controller
        return controller
    }

    fileprivate func connect(_ host: TerminalHost) {
        activeController?.newSSHSession(host)
    }

    fileprivate func perform(_ action: Selector) {
        guard let controller = activeController else { return }
        NSApp.sendAction(action, to: controller, from: nil)
    }
}

private struct EmbeddedTerminal: NSViewControllerRepresentable {
    let workspace: TerminalWorkspace
    let directory: URL
    let hosts: [TerminalHost]
    let host: TerminalHost?
    let toolbarInset: CGFloat

    func makeNSViewController(context: Context) -> NSViewController {
        let controller = workspace.controller(directory: directory, hosts: hosts, host: host)
        controller.toolbarInset = toolbarInset
        return controller
    }

    func updateNSViewController(_ controller: NSViewController, context: Context) {
        PtySession.configureSSHHosts(hosts)
        (controller as? TerminalViewController)?.toolbarInset = toolbarInset
    }
}

public struct TerminalCommands: Commands {
    let workspace: TerminalWorkspace
    let enabled: Bool
    let hosts: [TerminalHost]

    public init(workspace: TerminalWorkspace, enabled: Bool, hosts: [TerminalHost] = []) {
        self.workspace = workspace
        self.enabled = enabled
        self.hosts = hosts
    }

    public var body: some Commands {
        CommandMenu("Terminal") {
            Button("New Terminal Tab") { workspace.perform(#selector(TerminalViewController.newTab(_:))) }
                .disabled(!enabled)
            Button("Close Terminal Tab") { workspace.perform(#selector(TerminalViewController.closeActiveTabOrWindow(_:))) }
                .keyboardShortcut("w", modifiers: [.command, .shift]).disabled(!enabled)
            Menu("New SSH Terminal") {
                ForEach(hosts, id: \.id) { host in
                    Button(host.name) { workspace.connect(host) }
                }
            }.disabled(!enabled || hosts.isEmpty)
            Button("Reopen Closed Terminal Tab") { workspace.perform(#selector(TerminalViewController.reopenClosedTab(_:))) }
                .keyboardShortcut("t", modifiers: [.command, .shift]).disabled(!enabled)
            Button("Exit Terminal Session…") { workspace.perform(#selector(TerminalViewController.exitActiveSession(_:))) }
                .disabled(!enabled)
            Divider()
            Button("Find in Terminal History…") { workspace.perform(#selector(TerminalViewController.findInHistory(_:))) }
                .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(!enabled)
            Button("Clear Terminal") { workspace.perform(#selector(TerminalViewController.clearActiveTab(_:))) }
                .keyboardShortcut("k").disabled(!enabled)
            Button("Clear Command History…") { workspace.perform(#selector(TerminalViewController.clearCommandHistory(_:))) }
                .disabled(!enabled)
        }
    }
}

#endif

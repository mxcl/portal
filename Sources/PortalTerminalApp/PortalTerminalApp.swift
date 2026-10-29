#if os(macOS)
import AppKit
import SwiftUI
import PortalCore
import PortalEngine
import PortalTerminal

@main
struct PortalTerminalApp: App {
    @NSApplicationDelegateAdaptor(TerminalDelegate.self) private var delegate
    var body: some Scene {
        Settings { Text("Portal uses your Portal terminal sessions.").padding() }
        .commands {
            TerminalCommands(workspace: delegate.workspace, enabled: true, hosts: delegate.hosts,
                managesTabs: true, newWindow: { delegate.newWindow() },
                newSSHWindow: { delegate.newWindow(hostID: $0.id) })
        }
    }
}

@MainActor
final class TerminalDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var hosts: [TerminalHost] = []
    let workspace = TerminalWorkspace()
    private var openedWindow = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { if !self.openedWindow { self.newWindow(restoringWindows: true) } }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        newWindow(restoringWindows: !openedWindow)
        return false
    }

    func newWindow(directory: URL = FileManager.default.homeDirectoryForCurrentUser, command: String? = nil, hostID: String? = nil, restoringWindows: Bool = false, skipsSessionPicker: Bool = false) {
        openedWindow = true
        Task {
            let snapshot = try? await EngineClient.send(.snapshot).snapshot
            let savedURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Portal/Sync/config-v2.json")
            let saved = (try? Data(contentsOf: savedURL)).flatMap { try? JSONDecoder().decode(AppConfiguration.self, from: $0) }
            let hosts = (snapshot?.configuration ?? saved)?.hosts.map { host in
                TerminalHost(id: host.id.uuidString, name: host.name, peer: host.peer,
                             helperPath: host.executable.hasPrefix("/Applications/")
                                ? URL(fileURLWithPath: host.executable).deletingLastPathComponent()
                                    .deletingLastPathComponent().appendingPathComponent(host.executable.hasSuffix("/portald") ? "Helpers/portal-session-bridge" : "Helpers/gitinuum-session-bridge").path
                                : (host.executable.hasSuffix("/portald") ? "~/.local/lib/portal/terminal/portal-session-bridge" : "~/.local/lib/gitinuum/terminal/gitinuum-session-bridge"),
                             directory: host.root)
            } ?? []
            self.hosts = hosts
            if restoringWindows, workspace.restoreWindows(hosts: hosts) { return }
            if let hostID {
                guard let host = hosts.first(where: { $0.id == hostID }) else {
                    let alert = NSAlert()
                    alert.messageText = "SSH destination unavailable"
                    alert.informativeText = "This host is no longer configured in Portal."
                    alert.runModal()
                    return
                }
                workspace.newWindow(directory: URL(fileURLWithPath: host.directory), hosts: hosts, hostID: host.id)
            } else {
                workspace.newWindow(directory: directory, command: command, hosts: hosts, skipsSessionPicker: skipsSessionPicker)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let hostID = TerminalLaunchRequest.hostID(from: url) {
                newWindow(hostID: hostID)
                continue
            }
            guard url.isFileURL else { continue }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { continue }
            let command = directory.boolValue ? nil : "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            newWindow(directory: directory.boolValue ? url : url.deletingLastPathComponent(), command: command, skipsSessionPicker: true)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        workspace.saveWindows()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#else
@main enum PortalTerminalApp { static func main() {} }
#endif

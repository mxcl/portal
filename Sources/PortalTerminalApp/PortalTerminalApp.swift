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
        Settings { Text("Portal Terminal uses your Portal terminal sessions.").padding() }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Terminal Window") { delegate.newWindow() }.keyboardShortcut("n")
            }
            TerminalCommands(workspace: delegate.workspace, enabled: true)
        }
    }
}

@MainActor
final class TerminalDelegate: NSObject, NSApplicationDelegate {
    let workspace = TerminalWorkspace()
    private var openedWindow = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { if !self.openedWindow { self.newWindow() } }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        newWindow()
        return false
    }

    func newWindow(directory: URL = FileManager.default.homeDirectoryForCurrentUser, command: String? = nil) {
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
            workspace.newWindow(directory: directory, command: command, hosts: hosts)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.isFileURL {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { continue }
            let command = directory.boolValue ? nil : "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            newWindow(directory: directory.boolValue ? url : url.deletingLastPathComponent(), command: command)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#else
@main enum PortalTerminalApp { static func main() {} }
#endif

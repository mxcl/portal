#if os(macOS)
import AppKit
import PortalTerminal

@MainActor
enum TerminalApplication {
    static var url: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Portal Terminal.app")
    }

    static func open(_ urls: [URL] = []) {
        let configuration = NSWorkspace.OpenConfiguration()
        if urls.isEmpty {
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error { Task { @MainActor in NSAlert(error: error).runModal() } }
            }
        } else {
            NSWorkspace.shared.open(urls, withApplicationAt: url, configuration: configuration) { _, error in
                if let error { Task { @MainActor in NSAlert(error: error).runModal() } }
            }
        }
    }

    static func open(hostID: String) {
        open([TerminalLaunchRequest.url(hostID: hostID)])
    }

    static func install() {
        let panel = NSOpenPanel()
        panel.title = "Install Portal Terminal"
        panel.prompt = "Install Here"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let destination = directory.appendingPathComponent("Portal Terminal.app")
        do {
            // Refuse to overwrite an existing app; Finder can remove it when replacement is wanted.
            try FileManager.default.copyItem(at: url, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch { NSAlert(error: error).runModal() }
    }
}
#endif

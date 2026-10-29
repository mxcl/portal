#if os(macOS)
import AppKit
import PortalTerminal

@MainActor
enum TerminalApplication {
    static var url: URL {
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Portal.app")
        if FileManager.default.fileExists(atPath: sibling.path) { return sibling }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.mxcl.portal.terminal") ?? sibling
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

}
#endif

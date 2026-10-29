#if os(macOS)
import AppKit
import PortalTerminal

/// A development-only host for the real terminal views. It sends normal text-input
/// actions inside its own window; it never controls another app or posts mouse events.
@main
@MainActor
struct PortalFilm {
    static let workspace = TerminalWorkspace()

    static func input(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.isEditable,
           text.accessibilityLabel() == "Terminal command input" { return text }
        return view.subviews.lazy.compactMap { input(in: $0) }.first
    }

    static func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<600 {
            if predicate() { return }
            try await pause(0.05)
        }
        throw NSError(domain: "PortalFilm", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Terminal did not become ready"])
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                try await film()
                NSApp.terminate(nil)
            }
            catch { fputs("Film failed: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }

    static func film() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 else {
            throw NSError(domain: "PortalFilm", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "usage: PortalFilm <repository> <tools-directory> <output.mov>"])
        }
        let repo = URL(fileURLWithPath: args[1])
        let tools = URL(fileURLWithPath: args[2])
        let directory = tools.appendingPathComponent("orbit")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ready = tools.appendingPathComponent("shell-ready-\(UUID().uuidString)")
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let setup = "function orbit() { /usr/bin/python3 \(quote(repo.appendingPathComponent("scripts/demo/scene.py").path)) \"$@\"; }; touch \(quote(ready.path))"
        workspace.newWindow(directory: directory, command: setup, hosts: [], skipsSessionPicker: true)
        guard let window = NSApp.windows.first(where: { $0.contentViewController != nil }),
              let root = window.contentView, let editor = input(in: root), let screen = window.screen ?? NSScreen.main
        else { throw NSError(domain: "PortalFilm", code: 3) }
        window.level = .normal
        window.setContentSize(NSSize(width: 1120, height: 700))
        window.setFrameOrigin(NSPoint(x: screen.frame.midX - window.frame.width / 2,
                                      y: screen.frame.midY - window.frame.height / 2))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await waitUntil { FileManager.default.fileExists(atPath: ready.path) && !editor.isHiddenOrHasHiddenAncestor }
        try FileManager.default.removeItem(at: ready)
        guard NSApp.sendAction(NSSelectorFromString("clearActiveTab:"), to: window.contentViewController, from: nil)
        else { throw NSError(domain: "PortalFilm", code: 4) }
        let validateOnly = ProcessInfo.processInfo.environment["PORTAL_FILM_VALIDATE_ONLY"] == "1"
        let background = Process()
        background.executableURL = tools.appendingPathComponent("backdrop")
        background.arguments = [String(window.windowNumber), String(ProcessInfo.processInfo.processIdentifier)]
        if !validateOnly { try background.run() }
        defer { if background.isRunning { background.terminate() } }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        NSApp.activate(ignoringOtherApps: true)
        try await pause(1)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await waitUntil { NSApp.isActive && window.isKeyWindow }

        let capture = Process()
        capture.executableURL = tools.appendingPathComponent("record")
        capture.arguments = [args[3], "46", "--display"]
        let readyFile = tools.appendingPathComponent("capture-ready-\(UUID().uuidString)")
        capture.environment = ProcessInfo.processInfo.environment.merging(["PORTAL_FILM_READY_FILE": readyFile.path, "PORTAL_FILM_BUNDLE_ID": Bundle.main.bundleIdentifier!]) { _, new in new }
        if !validateOnly { try capture.run() }
        defer { if capture.isRunning { capture.terminate() } }
        if !validateOnly {
            try await waitUntil { FileManager.default.fileExists(atPath: readyFile.path) || !capture.isRunning }
            guard capture.isRunning else { throw NSError(domain: "PortalFilm", code: 5) }
            try FileManager.default.removeItem(at: readyFile)
        }
        let start = ContinuousClock.now
        let cues: [(Double, String)] = [(2,"explore"),(6,"graph"),(10,"check"),(14,"build"),
            (19,"test"),(23,"bench"),(27,"diff"),(31,"assets"),(35,"status"),(39,"preview")]
        for (at, scene) in cues {
            if !validateOnly { try await Task.sleep(until: start.advanced(by: .seconds(at)), clock: .continuous) }
            try await waitUntil { !editor.isHiddenOrHasHiddenAncestor }
            let command = "orbit " + scene
            for (index, character) in command.enumerated() {
                editor.insertText(String(character), replacementRange: editor.selectedRange())
                try await pause(validateOnly ? 0.001 : index == 5 ? 0.20 : 0.085 + Double(index % 3) * 0.015)
            }
            try await pause(0.35)
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            try await waitUntil { editor.string.isEmpty && !editor.isHiddenOrHasHiddenAncestor }
            try await pause(0.2)
            func scrolls(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
            }
            if let history = scrolls(root).max(by: { $0.frame.height < $1.frame.height }) {
                guard history.contentView.bounds.maxY >= history.documentView!.bounds.height + history.contentInsets.bottom - 1
                else { throw NSError(domain: "PortalFilm", code: 7, userInfo: [NSLocalizedDescriptionKey: "Output fell behind composer after \(command)"]) }
                print("SCROLL \(command) clip=\(history.contentView.bounds) doc=\(history.documentView!.bounds) inset=\(history.contentInsets)")
            }
            print("COMPLETED \(command)"); fflush(stdout)
        }
        if !validateOnly {
            try await waitUntil { !capture.isRunning }
            guard capture.terminationStatus == 0 else { throw NSError(domain: "PortalFilm", code: 6) }
        }
        print("FILM COMPLETE \(args[3])"); fflush(stdout)
    }
}
#endif

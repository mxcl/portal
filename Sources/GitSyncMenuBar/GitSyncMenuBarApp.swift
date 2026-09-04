#if os(macOS)
import AppKit
import Combine
import ServiceManagement
import SwiftUI
import GitSyncEngine

@main
struct GitSyncMenuBarApp: App {
    @StateObject private var runtime = MenuBarRuntime()

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(runtime: runtime)
        } label: {
            Label("Git Sync", systemImage: runtime.model.isPaused
                  ? "pause.circle" : "arrow.triangle.2.circlepath")
        }
    }
}

@MainActor
private final class MenuBarRuntime: ObservableObject {
    let model: EngineModel
    private let server: EngineControlServer?
    private var observation: AnyCancellable?
    private var terminationObservation: AnyCancellable?

    init() {
        model = EngineModel(executableURL: Self.gitSyncExecutableURL)
        server = try? EngineControlServer()
        server?.start(model: model)
        observation = model.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
            DispatchQueue.main.async {
                DistributedNotificationCenter.default().postNotificationName(
                    EngineControlProtocol.changedNotification,
                    object: nil,
                    deliverImmediately: true
                )
            }
        }
        terminationObservation = NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.model.shutdown() }
    }

    func quitEverything() {
        model.shutdown()
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "dev.mxcl.git-sync") {
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
        outerApplicationURL.appendingPathComponent("Contents/Resources/git-sync")
    }

    static func openMainApplication() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: outerApplicationURL, configuration: configuration)
    }
}

private struct StatusMenu: View {
    @ObservedObject var runtime: MenuBarRuntime

    var body: some View {
        Text(runtime.model.status)
        if !runtime.model.menuLogs.isEmpty {
            Divider()
            Section("Event Log") {
                ForEach(Array(runtime.model.menuLogs.enumerated()), id: \.offset) { Text($0.element) }
            }
        }
        Divider()
        Button(runtime.model.isPaused ? "Resume Sync" : "Pause Sync") {
            runtime.model.isPaused ? runtime.model.resume() : runtime.model.pause()
        }
        .disabled(!runtime.model.isConfigured)
        Button("Open Git Sync") {
            MenuBarRuntime.openMainApplication()
        }
        Button("Settings…") {
            if let url = URL(string: "gitsync://settings") {
                NSWorkspace.shared.open(url)
            }
        }
        .keyboardShortcut(",", modifiers: .command)
        if SMAppService.loginItem(identifier: "dev.mxcl.git-sync.menu").status == .requiresApproval {
            Button("Login Items…") { SMAppService.openSystemSettingsLoginItems() }
        }
        Divider()
        Button("Quit Git Sync", action: runtime.quitEverything)
    }
}
#else
import Foundation
@main enum GitSyncMenuBarApp { static func main() { print("Git Sync Menu is available on macOS only") } }
#endif

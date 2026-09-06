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
                .task { await runtime.model.refreshProjectStatuses() }
        } label: {
            Label("Gitinuum", systemImage: runtime.model.isPaused
                  ? "pause.circle" : "arrow.triangle.2.circlepath")
        }
    }
}

@MainActor
final class MenuBarRuntime: ObservableObject {
    let model: EngineModel
    private let server: EngineControlServer?
    private var observation: AnyCancellable?
    private var terminationObservation: AnyCancellable?
    private let shortcut = GlobalShortcut()
    private var shortcutObservation: AnyCancellable?

    init() {
        model = EngineModel(executableURL: Self.gitSyncExecutableURL)
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
        outerApplicationURL.appendingPathComponent("Contents/Resources/gitinuumd")
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
        if let error = runtime.model.globalShortcutError { Text(error) }
        Divider()
        Section("Project Status") {
            if runtime.model.localProjects.isEmpty {
                Text("No local repositories")
            }
            ForEach(runtime.model.localProjects.keys.sorted(), id: \.self) { name in
                Button {
                    var url = URLComponents()
                    url.scheme = "gitsync"
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
        Menu("Events") {
            if runtime.model.menuLogs.isEmpty {
                Text("No events yet")
            } else {
                ForEach(Array(runtime.model.menuLogs.enumerated()), id: \.offset) { Text($0.element) }
            }
        }
        Divider()
        Button(runtime.model.isPaused ? "Resume Sync" : "Pause Sync") {
            runtime.model.isPaused ? runtime.model.resume() : runtime.model.pause()
        }
        .disabled(!runtime.model.isConfigured)
        Button("Open Gitinuum") {
            MenuBarRuntime.openMainApplication()
        }
        Button("Settings…") {
            if let url = URL(string: "gitsync://settings") {
                NSWorkspace.shared.open(url)
            }
        }
        .keyboardShortcut(",", modifiers: .command)
        if SMAppService.loginItem(identifier: "dev.mxcl.git-sync.menu-helper").status == .requiresApproval {
            Button("Login Items…") { SMAppService.openSystemSettingsLoginItems() }
        }
        Divider()
        Button("Quit Gitinuum", action: runtime.quitEverything)
    }
}
#else
import Foundation
@main enum GitSyncMenuBarApp { static func main() { print("Gitinuum Menu Helper is available on macOS only") } }
#endif

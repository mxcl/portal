#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# Launch Services ignores URL handlers under /tmp; use an isolated test app.
mkdir -p "$HOME/Applications"
scratch=$(mktemp -d "$HOME/Applications/gitinuum-window-test.XXXXXX")
app="$scratch/Probe.app"
registry=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
trap '"$registry" -u "$app" >/dev/null 2>&1; rm -rf "$scratch"' EXIT
mkdir -p "$app/Contents/MacOS"
python3 - "$repo" "$scratch" <<'PY'
import pathlib, plistlib, sys
repo, scratch = map(pathlib.Path, sys.argv[1:])
scheme = scratch.name.lower().replace('.', '-')
plist = dict(CFBundleIdentifier='dev.mxcl.' + scheme, CFBundleExecutable='Probe',
             CFBundleName='Gitinuum Window Test', CFBundleVersion='1', CFBundlePackageType='APPL',
             CFBundleURLTypes=[dict(CFBundleTypeRole='Viewer', CFBundleURLName='Window Test',
                                   CFBundleURLSchemes=[scheme])])
(scratch / 'Probe.app/Contents/Info.plist').write_bytes(plistlib.dumps(plist))
source = (repo / 'Sources/GitSyncApp/ProjectEditor.swift').read_text()
guard = source[source.index('struct EditorCloseGuard:'):source.index('\nstruct ProjectFileBrowser:')]
(scratch / 'Guard.swift').write_text('import AppKit\nimport SwiftUI\n' + guard)
(scratch / 'scheme').write_text(scheme)
PY
cat > "$scratch/Probe.swift" <<'SWIFT'
import AppKit
import SwiftUI

@MainActor final class ProjectEditor: ObservableObject {
    let path: String? = "test.txt"
    @Published var isDirty = false
    func save() -> Bool { false }
    func discard() { isDirty = false }
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    static let editor = ProjectEditor()
    static var receivedURLs = 0
    private let result = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("result")
    private var projectWindow: NSWindow? { NSApp.windows.first { $0.identifier?.rawValue == "projects" } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            guard let window = projectWindow, window.isVisible, !window.isMiniaturized,
                  Self.receivedURLs == 1 else { finish("FAIL: URL launch did not show the project window"); return }
            window.miniaturize(nil)
            let scheme = try! String(contentsOf: result.deletingLastPathComponent().appendingPathComponent("scheme"), encoding: .utf8)
            NSWorkspace.shared.open(URL(string: "\(scheme)://project?name=second")!)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                guard window.isVisible, !window.isMiniaturized, Self.receivedURLs == 2,
                      NSApp.windows.filter({ $0.identifier?.rawValue == "projects" }).count == 1 else {
                    finish("FAIL: second URL: visible=\(window.isVisible), minimized=\(window.isMiniaturized), URLs=\(Self.receivedURLs), windows=\(NSApp.windows.count)"); return
                }
                finish("PASS: URL launch and minimized-window reuse")
            }
        }
    }

    private func finish(_ message: String) {
        try! (message + "\n").write(to: result, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}

@main struct Probe: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate
    var body: some Scene {
        Window("Gitinuum", id: "projects") {
            Text("Project")
                .onOpenURL { _ in Delegate.receivedURLs += 1; NSApp.activate() }
                .modifier(EditorCloseGuard(editor: Delegate.editor))
        }
        Settings { Text("Settings") }
    }
}
SWIFT
swiftc -parse-as-library "$scratch/Guard.swift" "$scratch/Probe.swift" -o "$app/Contents/MacOS/Probe"
"$registry" -f "$app"
# Launch by URL alone, exactly as the menu helper does, without an app-open event.
open "$(cat "$scratch/scheme")://project?name=first"
for attempt in $(seq 1 50); do
    test ! -f "$scratch/result" || break
    sleep 0.1
done
cat "$scratch/result"
grep -q '^PASS:' "$scratch/result"

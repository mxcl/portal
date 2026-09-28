#!/usr/bin/env python3
"""Exercise the actual model-to-menu observation bridge in AppKit tracking mode."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
source = (repo / 'Sources/GitSyncMenuBar/GitSyncMenuBarApp.swift').read_text()
bridge = source.split('        observation = model.objectWillChange.sink', 1)[1].split('        terminationObservation =', 1)[0]
program = '''
import AppKit
import Combine

// Isolate the production bridge from daemon, shortcut and network startup.
enum EngineControlProtocol {
    static let changedNotification = Notification.Name("dev.mxcl.git-sync.menu-tracking-test")
}
@MainActor final class Model: ObservableObject { @Published var value = 0 }
@MainActor final class Runtime: ObservableObject {
    let model = Model()
    var observation: AnyCancellable?
    init() {
        observation = model.objectWillChange.sink''' + bridge + '''
    }
}
@main enum Check {
    @MainActor static func main() {
        let runtime = Runtime()
        var updates = 0
        let observation = runtime.objectWillChange.sink { updates += 1 }
        var changed = false
        RunLoop.main.perform(inModes: [.eventTracking]) {
            MainActor.assumeIsolated {
                runtime.model.value = 1
                runtime.model.value = 1 // Identical published values still invalidate the menu.
                changed = true
            }
        }
        RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.05))
        assert(changed, "Tracking-mode stimulus did not run")
        assert(updates == 0, "Engine updates invalidate the menu while a submenu is open")
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        assert(updates > 0, "Menu must catch up after tracking ends")
        withExtendedLifetime(observation) {}
        print("Menu updates wait until tracking ends")
    }
}
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path / 'Check.swift').write_text(program)
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'Check.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)

#!/usr/bin/env python3
"""Render the real menu label against the installed helper's resources."""
from pathlib import Path
import subprocess
import tempfile
import sys

repo = Path(__file__).resolve().parent.parent
source = (repo / 'Sources/PortalMenuBar/PortalMenuBarApp.swift').read_text()
view = source[source.index('private struct MenuBarIcon:'):source.index('@MainActor\nfinal class MenuBarRuntime')]
helper = str(Path(sys.argv[1] if len(sys.argv) > 1 else '/Applications/Portal.app') / 'Contents/Library/LoginItems/Portal Menu Helper.app')
import json
program = 'import AppKit\nimport SwiftUI\nlet bundle = Bundle(path: ' + json.dumps(helper) + ')!\n'
program += view.replace('Bundle.main', 'bundle')
program += '''
MainActor.assumeIsolated {
    for unread in [false, true] {
        let renderer = ImageRenderer(content: MenuBarIcon(isPaused: false, hasUnreadNotifications: unread))
        renderer.scale = 2
        guard let data = renderer.nsImage?.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data) else { fatalError("Missing menu icon") }
        assert(bitmap.pixelsWide == 32 && bitmap.pixelsHigh == 40, "Unexpected menu icon spacing")
        // Check the icon's center, excluding the unread badge in the top-right corner.
        let visible = (8..<24).contains { x in (8..<28).contains { y in
            (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0
        }}
        assert(visible, "Portal menu icon is blank")
    }
    print("Portal menu icon renders visible pixels with and without its badge")
}
'''
with tempfile.TemporaryDirectory(prefix='portal-icon-test-') as temporary:
    script = Path(temporary) / 'check.swift'
    script.write_text(program)
    subprocess.run(['swift', str(script)], check=True)

    # Exercise MenuBarExtra's native bridge: ImageRenderer alone cannot detect
    # template metadata being lost before the image reaches NSStatusBarButton.
    native = 'import AppKit\nimport SwiftUI\nlet bundle = Bundle(path: ' + json.dumps(helper) + ')!\n'
    native += view.replace('Bundle.main', 'bundle')
    native += '''
@main struct MenuIconProbe: App {
    init() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            var images: [NSImage] = []
            func inspect(_ view: NSView) {
                if let button = view as? NSStatusBarButton, let image = button.image {
                    images.append(image)
                }
                for child in view.subviews { inspect(child) }
            }
            for window in NSApp.windows {
                if let content = window.contentView { inspect(content) }
            }
            guard images.count == 4, images.allSatisfy({ $0.isTemplate }) else {
                fputs("MenuBarExtra must deliver template images to every status button\\n", stderr)
                exit(1)
            }
            print("Native menu icons retain template tinting for paused and unread states")
            NSApp.terminate(nil)
        }
    }
    var body: some Scene {
'''
    for paused in ['false', 'true']:
        for unread in ['false', 'true']:
            native += f'''        MenuBarExtra {{ Text("Icon test") }} label: {{
            MenuBarIcon(isPaused: {paused}, hasUnreadNotifications: {unread})
        }}
'''
    native += '    }\n}\n'
    script.write_text(native)
    executable = Path(temporary) / 'check'
    subprocess.run(['swiftc', '-parse-as-library', str(script), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=15)

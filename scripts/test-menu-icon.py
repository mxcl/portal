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
        // Check the icon's center, excluding the unread badge in the top-right corner.
        let visible = (8..<28).contains { x in (8..<28).contains { y in
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

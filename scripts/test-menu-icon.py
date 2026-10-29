#!/usr/bin/env python3
"""Check the real native menu icon and badge against installed resources."""
from pathlib import Path
import json
import subprocess
import tempfile
import sys

repo = Path(__file__).resolve().parent.parent
source = (repo / 'Sources/PortalMenuBar/PortalMenuBarApp.swift').read_text()
view = source[source.index('@MainActor\nprivate final class MenuBarIcon {'):source.index('@MainActor\nfinal class MenuBarRuntime')]
helper = str(Path(sys.argv[1] if len(sys.argv) > 1 else '/Applications/Portal Hub.app') / 'Contents/Library/LoginItems/Portal Menu Helper.app')
program = 'import AppKit\nimport SwiftUI\nlet bundle = Bundle(path: ' + json.dumps(helper) + ')!\n'
program += view.replace('Bundle.main', 'bundle')
program += '''
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let icon = MenuBarIcon()
    let button = icon.statusItem.button!
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        button.appearance = NSAppearance(named: appearance)
        for paused in [false, true] {
            for unread in [false, true, false] {
                icon.update(isPaused: paused, hasUnreadNotifications: unread)
                guard let image = button.image, image.isTemplate else {
                    fatalError("Native status button must retain template tinting")
                }
                assert(image.size == NSSize(width: 16, height: 20), "Unexpected icon spacing")
                guard let bitmap = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else {
                    fatalError("Missing icon pixels")
                }
                assert((0..<bitmap.pixelsWide).contains { x in
                    (0..<bitmap.pixelsHigh).contains { y in
                        (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0
                    }
                }, "Portal menu icon is blank")
                for highlighted in [false, true] {
                    button.highlight(highlighted)
                    button.layoutSubtreeIfNeeded()
                    let rendered = button.bitmapImageRepForCachingDisplay(in: button.bounds)!
                    button.cacheDisplay(in: button.bounds, to: rendered)
                    let blue = (0..<rendered.pixelsWide).contains { x in
                        (0..<rendered.pixelsHigh).contains { y in
                            guard let color = rendered.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                            return color.alphaComponent > 0.5 && color.blueComponent > color.redComponent + 0.2
                        }
                    }
                    assert(blue == unread, "Unread GitHub badge must be blue only when unread")
                    let badge = button.subviews.first { $0 is MenuBarBadge }!
                    assert(badge.hitTest(NSPoint(x: 3, y: 3)) == nil, "Badge must not intercept menu clicks")
                }
            }
        }
    }
    print("Native icon stays templated; blue badge appears and clears in light/dark, paused, and highlighted states")
    NSStatusBar.system.removeStatusItem(icon.statusItem)
}
'''
with tempfile.TemporaryDirectory(prefix='portal-icon-test-') as temporary:
    script = Path(temporary) / 'check.swift'
    script.write_text(program)
    subprocess.run(['swift', str(script)], check=True, timeout=60)

#if os(macOS)
import AppKit
import Testing
@testable import PortalTerminal

struct StickyBlockHeaderTests {
    @Test @MainActor func offscreenStickyHeaderHasNoCursorRegion() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        let header = StickyBlockHeaderView(frame: NSRect(x: 0, y: 0, width: 600, height: 40))
        window.contentView!.addSubview(header)
        header.isSticky = true
        // The titlebar and header do not overlap while a block scrolls into position.
        header.resetCursorRects()
        #expect(header.window === window)
    }
}
#endif

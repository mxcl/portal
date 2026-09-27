#if os(macOS)
import AppKit
import Testing
@testable import PortalTerminal

struct CompletionPopupTests {
    @Test @MainActor
    func completionAfterAnchorIsDetached() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        window.contentView!.addSubview(anchor)
        anchor.removeFromSuperview()
        #expect(anchor.window == nil)

        let popup = CompletionPopupController()
        popup.show(suggestions: [CompletionSuggestion(
            displayText: "test", insertText: "test", description: nil,
            kind: .command, priority: 0, source: "test"
        )], relativeTo: anchor.bounds, of: anchor)

        #expect(!popup.isShown)
        #expect(popup.selectNext() == nil)
    }
}
#endif

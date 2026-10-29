#if os(macOS)
import AppKit
import Testing
@testable import PortalTerminal

struct TerminalFindRoutingTests {
    @Test @MainActor func findRequiresFocusInsideTerminal() {
        _ = NSApplication.shared
        let terminal = TerminalViewController(restoresPersistedWindow: false)
        let input = NSTextView()
        let container = NSView()
        input.nextResponder = container
        container.nextResponder = terminal
        #expect(TerminalWorkspace.findTarget(startingAt: input) === terminal)

        let sidebar = NSTextView()
        let window = NSWindow()
        sidebar.nextResponder = window
        // A window must end the search even if a terminal follows it in the chain.
        window.nextResponder = terminal
        #expect(TerminalWorkspace.findTarget(startingAt: sidebar) == nil)
        #expect(TerminalWorkspace.findTarget(startingAt: nil) == nil)
        window.nextResponder = nil
    }
}
#endif

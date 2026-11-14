#if os(macOS)
import AppKit
import Testing
@testable import PortalTerminal

@Test("Terminal icon buttons visibly highlight and release")
@MainActor
func terminalButtonPressFeedback() throws {
    for button in [
        HoverCopyMarkdownButton(),
        TerminalIconButton(symbol: "arrow.up.to.line", label: "Scroll to top"),
        TerminalIconButton(symbol: "arrow.down.to.line", label: "Scroll to bottom"),
    ] {
        let cell = try #require(button.cell)
        let idleColor = try #require(button.layer?.backgroundColor)
        cell.isHighlighted = true
        #expect(button.layer?.backgroundColor != idleColor)
        #expect(button.contentTintColor == .labelColor)
        cell.isHighlighted = false
        #expect(button.layer?.backgroundColor == idleColor)
    }
}

@Test("Copy confirmation restores its icon and accessible label")
@MainActor
func terminalCopyFeedback() {
    let button = HoverCopyMarkdownButton()
    let originalIcon = button.image?.tiffRepresentation
    defer { NSObject.cancelPreviousPerformRequests(withTarget: button) }
    button.showCopied()
    #expect(button.image?.tiffRepresentation != originalIcon)
    #expect(button.accessibilityLabel() == "Copied")
    #expect(button.toolTip == "Copied")
    button.showCopied()
    button.resetCopyFeedback()
    #expect(button.image?.tiffRepresentation == originalIcon)
    #expect(button.accessibilityLabel() == "Copy Markdown")
    #expect(button.toolTip == "Copy Markdown")
}
#endif

#if os(macOS)
import AppKit

// Imported from the original Portal title-bar material.
final class TrafficLightBorderView: NSVisualEffectView {
    var buttonFrames: [NSRect] = [] {
        didSet { updateMask() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func updateMask() {
        let buttonFrames = buttonFrames
        maskImage = NSImage(size: bounds.size, flipped: false) { _ in
            NSColor.white.setFill()
            buttonFrames.forEach {
                NSBezierPath(ovalIn: $0.insetBy(dx: -2.5, dy: -2.5)).fill()
            }
            return true
        }
    }
}

#endif

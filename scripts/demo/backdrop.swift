import AppKit

// Standalone scenery for filming the real Portal window. No Portal state is changed.
final class Backdrop: NSView {
    let start = Date()
    override func draw(_ rect: NSRect) {
        let w = bounds.width, h = bounds.height
        let t = Date().timeIntervalSince(start)
        NSColor(calibratedRed: 0.018, green: 0.025, blue: 0.07, alpha: 1).setFill()
        bounds.fill()
        let colors: [NSColor] = [
            NSColor(calibratedRed: 0.08, green: 0.36, blue: 1, alpha: 1),
            NSColor(calibratedRed: 0.49, green: 0.12, blue: 0.94, alpha: 1),
            NSColor(calibratedRed: 1, green: 0.48, blue: 0.3, alpha: 1)]
        for i in 0..<3 {
            let phase = t * 0.16 + Double(i) * 2.1
            let x = w * (0.5 + 0.42 * sin(phase))
            let y = h * (0.5 + 0.42 * cos(phase * 0.8))
            let glow = NSGradient(starting: colors[i].withAlphaComponent(0.55), ending: colors[i].withAlphaComponent(0))!
            glow.draw(fromCenter: NSPoint(x: x, y: y), radius: 0,
                      toCenter: NSPoint(x: x, y: y), radius: w * 0.52, options: [])
            let ribbon = NSBezierPath()
            ribbon.move(to: NSPoint(x: x - w * 0.7, y: y - h * 0.5))
            ribbon.curve(to: NSPoint(x: x + w * 0.55, y: y + h * 0.7),
                         controlPoint1: NSPoint(x: x + w * 0.5, y: y - h * 0.6),
                         controlPoint2: NSPoint(x: x - w * 0.5, y: y + h * 0.6))
            ribbon.lineWidth = w * (i == 2 ? 0.018 : 0.045)
            colors[i].withAlphaComponent(0.65).setStroke()
            ribbon.stroke()
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.main!
let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
window.title = "Portal Film Backdrop"
window.isOpaque = true
window.hasShadow = false
window.level = .normal
let view = Backdrop(frame: screen.frame)
window.contentView = view
window.makeKeyAndOrderFront(nil)
if CommandLine.arguments.count > 1, let target = Int(CommandLine.arguments[1]) {
    window.order(.below, relativeTo: target)
}
print("SCREEN \(screen.frame) SCALE \(screen.backingScaleFactor)")
fflush(stdout)
let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in view.needsDisplay = true }
app.run()

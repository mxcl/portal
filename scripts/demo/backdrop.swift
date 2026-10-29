import AppKit
import QuartzCore

// GPU-composited pools and caustics: geometry stays crisp outside the terminal,
// while the terminal's own material supplies the blur inside it.
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    NSColor(calibratedRed: r, green: g, blue: b, alpha: a).cgColor
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.main!
let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
window.title = "Portal Film Backdrop"
window.isOpaque = true
window.hasShadow = false
window.level = .normal
window.ignoresMouseEvents = true
let view = NSView(frame: screen.frame)
view.wantsLayer = true
let root = view.layer!
root.backgroundColor = color(0.025, 0.035, 0.075)
root.masksToBounds = true
let w = screen.frame.width, h = screen.frame.height

func drift(_ layer: CALayer, index: Int, radius: CGFloat, duration: Double) {
    let center = layer.position
    let path = CGMutablePath()
    path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius * 0.5,
                              width: radius * 2, height: radius))
    let motion = CAKeyframeAnimation(keyPath: "position")
    motion.path = path
    motion.calculationMode = .paced
    motion.duration = duration
    motion.repeatCount = .infinity
    motion.timeOffset = Double(index) * duration / 5
    layer.add(motion, forKey: "drift")
    let breathe = CABasicAnimation(keyPath: "transform.scale")
    breathe.fromValue = 0.88
    breathe.toValue = 1.16
    breathe.duration = duration * 0.4
    breathe.autoreverses = true
    breathe.repeatCount = .infinity
    breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    layer.add(breathe, forKey: "breathe")
}
// One shared timeline lets the pools, caustics, and dark ground change together.
typealias RGB = (CGFloat, CGFloat, CGFloat)
let palettes: [[RGB]] = [
    [(0.12, 0.36, 0.95), (0.44, 0.23, 0.88), (0.95, 0.53, 0.42), (0.22, 0.64, 0.83)],
    [(0.06, 0.72, 0.60), (0.10, 0.39, 0.64), (0.68, 0.91, 0.57), (0.32, 0.82, 0.83)],
    [(0.98, 0.48, 0.15), (0.74, 0.24, 0.34), (1.00, 0.78, 0.40), (0.95, 0.62, 0.46)],
    [(0.50, 0.20, 0.91), (0.88, 0.28, 0.60), (0.38, 0.42, 0.95), (0.77, 0.54, 0.94)]
]
let paletteStart = CACurrentMediaTime()
func cycle(_ layer: CALayer, keyPath: String, values: [Any]) {
    let animation = CAKeyframeAnimation(keyPath: keyPath)
    animation.values = values + [values[0]]
    animation.keyTimes = [0, 0.25, 0.5, 0.75, 1]
    animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
    animation.duration = 48
    animation.beginTime = paletteStart
    animation.repeatCount = .infinity
    layer.add(animation, forKey: "palette")
}
cycle(root, keyPath: "backgroundColor", values: [
    color(0.025, 0.035, 0.075), color(0.015, 0.065, 0.06),
    color(0.085, 0.035, 0.025), color(0.055, 0.02, 0.085)
])
let centers: [CGPoint] = [CGPoint(x: w * 0.22, y: h * 0.5), CGPoint(x: w * 0.76, y: h * 0.75),
                          CGPoint(x: w * 0.7, y: h * 0.12), CGPoint(x: w * 0.18, y: h * 0.92)]
for i in palettes[0].indices {
    let glow = CAGradientLayer()
    glow.type = .radial
    glow.bounds = CGRect(x: 0, y: 0, width: w * 1.1, height: h * 1.45)
    glow.position = centers[i]
    glow.startPoint = CGPoint(x: 0.5, y: 0.5)
    glow.endPoint = CGPoint(x: 1, y: 1)
    let colors = palettes.map { palette -> [CGColor] in
        let rgb = palette[i]
        return [0.9, 0.32, 0].map { color(rgb.0, rgb.1, rgb.2, $0) }
    }
    glow.colors = colors[0]
    cycle(glow, keyPath: "colors", values: colors)
    glow.locations = [0, 0.35, 1]
    root.addSublayer(glow)
    drift(glow, index: i, radius: w * 0.23, duration: 23 + Double(i) * 3)
}
for i in 0..<3 {
    let lens = CAGradientLayer()
    lens.type = .radial
    lens.bounds = CGRect(x: 0, y: 0, width: w * 1.1, height: h * 0.78)
    lens.position = CGPoint(x: w * (0.26 + Double(i) * 0.22), y: h * (0.3 + Double(i) * 0.2))
    lens.startPoint = CGPoint(x: 0.5, y: 0.5)
    lens.endPoint = CGPoint(x: 1, y: 1)
    let colors = palettes.map { palette -> [CGColor] in
        let rgb = palette[(i + 1) % palette.count]
        let light = (0.65 + rgb.0 * 0.35, 0.65 + rgb.1 * 0.35, 0.65 + rgb.2 * 0.35)
        return [color(rgb.0 * 0.1, rgb.1 * 0.1, rgb.2 * 0.1, 0.14),
                color(rgb.0 * 0.1, rgb.1 * 0.1, rgb.2 * 0.1, 0.02),
                color(light.0, light.1, light.2, 0.03),
                color(light.0, light.1, light.2, 0.38),
                color(light.0, light.1, light.2, 0)]
    }
    lens.colors = colors[0]
    cycle(lens, keyPath: "colors", values: colors)
    lens.locations = [0, 0.56, 0.68, 0.76, 0.92]
    lens.transform = CATransform3DMakeRotation(-0.55 + Double(i) * 0.3, 0, 0, 1)
    root.addSublayer(lens)
    drift(lens, index: i + 1, radius: w * 0.2, duration: 28 + Double(i) * 4)
}
window.contentView = view
window.orderFrontRegardless()
if CommandLine.arguments.count > 1, let target = Int(CommandLine.arguments[1]) {
    window.order(.below, relativeTo: target)
}
print("SCREEN \(screen.frame) SCALE \(screen.backingScaleFactor)")
fflush(stdout)
// A killed or closed filming host must never leave scenery on the desktop.
if CommandLine.arguments.count > 2, let parent = Int32(CommandLine.arguments[2]) {
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
        if getppid() != parent { NSApplication.shared.terminate(nil) }
    }
}
app.run()

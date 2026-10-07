#if os(macOS)
import SwiftUI

/// A fixed instrument lane: healthy/inactive state has no illuminated color.
struct SidebarLED: View {
    enum Tone { case off, white, blue, amber, red }
    let tone: Tone
    let label: String
    var transferring = false
    var outputAt: Date? = nil
    var outputMaxAge: TimeInterval = 0.3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var outputPulse = false

    private var color: Color {
        if outputPulse { return .white }
        switch tone {
        case .off: return Color(red: 0.21, green: 0.27, blue: 0.29)
        case .white: return Color(red: 0.80, green: 0.87, blue: 0.88)
        case .blue: return Color(red: 0.55, green: 0.79, blue: 0.87)
        case .amber: return Color(red: 0.93, green: 0.73, blue: 0.46)
        case .red: return Color(red: 0.96, green: 0.34, blue: 0.30)
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.15, paused: !transferring || reduceMotion)) { context in
            let transferLit = !transferring || reduceMotion
                || Int(context.date.timeIntervalSinceReferenceDate / 0.3).isMultiple(of: 2)
            RoundedRectangle(cornerRadius: 1)
                .fill(color.opacity(outputPulse && tone == .white ? 0.2 : transferLit ? 1 : 0.2))
                .frame(width: 10, height: 4)
                .overlay(RoundedRectangle(cornerRadius: 1).strokeBorder(.black.opacity(0.45), lineWidth: 0.5))
                .shadow(color: tone == .off && !outputPulse ? .clear : color.opacity(0.35), radius: 2)
                .frame(width: 18, height: 24)
        }
        .help(label)
        .accessibilityLabel(label)
        .task(id: outputAt) {
            outputPulse = false
            guard let outputAt, Date().timeIntervalSince(outputAt) < outputMaxAge, !reduceMotion else { return }
            outputPulse = true
            do { try await Task.sleep(for: .milliseconds(120)) }
            catch { return }
            outputPulse = false
        }
    }
}
#endif

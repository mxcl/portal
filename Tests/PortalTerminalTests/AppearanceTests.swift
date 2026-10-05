#if os(macOS)
import AppKit
import Testing
@testable import PortalTerminal

@Test("Translucent terminal labels resolve again after appearance changes")
@MainActor
func terminalLabelAppearanceChanges() throws {
    let color = appearanceAlpha(.labelColor, 0.34)
    var brightness: [CGFloat] = []
    for name in [NSAppearance.Name.darkAqua, .aqua, .darkAqua] {
        let appearance = try #require(NSAppearance(named: name))
        appearance.performAsCurrentDrawingAppearance {
            brightness.append(color.usingColorSpace(.deviceRGB)!.redComponent)
        }
    }
    #expect(brightness[0] > brightness[1] + 0.5)
    #expect(abs(brightness[0] - brightness[2]) < 0.01)
}
#endif

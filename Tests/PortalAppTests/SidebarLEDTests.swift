#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import PortalApp

@Test("Sidebar lamps render dark idle state and distinct attention colors",
      arguments: [SidebarLED.Tone.off, .white, .blue, .amber, .red])
@MainActor
func sidebarLEDColors(tone: SidebarLED.Tone) throws {
    let renderer = ImageRenderer(content: SidebarLED(tone: tone, label: "Status"))
    renderer.scale = 2
    let image = try #require(renderer.nsImage)
    let data = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: data))
    let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
    #expect(color.alphaComponent > 0.9)
    switch tone {
    case .off: #expect(color.redComponent < 0.4 && color.greenComponent < 0.4 && color.blueComponent < 0.4)
    case .white: #expect(color.redComponent > 0.7 && color.blueComponent > 0.7)
    case .blue: #expect(color.blueComponent > color.redComponent + 0.2)
    case .amber: #expect(color.redComponent > color.greenComponent && color.greenComponent > color.blueComponent)
    case .red: #expect(color.redComponent > color.greenComponent + 0.4)
    }
}
#endif

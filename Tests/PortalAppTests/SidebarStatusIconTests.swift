#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import PortalApp

@Test("Sidebar status icons render visible pixels from the bundled resources",
      arguments: ["backup", "terminal", "branch-difference"])
@MainActor
func sidebarStatusIconRenders(name: String) throws {
    let renderer = ImageRenderer(content: SidebarStatusIcon(name: name, color: .gray))
    renderer.scale = 2
    let image = try #require(renderer.nsImage)
    let data = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: data))
    let visiblePixels = (0..<bitmap.pixelsWide).reduce(0) { count, x in
        count + (0..<bitmap.pixelsHigh).filter {
            (bitmap.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.1
        }.count
    }
    #expect(visiblePixels > 0)
}
#endif

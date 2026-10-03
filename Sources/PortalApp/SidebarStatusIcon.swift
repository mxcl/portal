#if os(macOS)
import AppKit
import SwiftUI

struct SidebarStatusIcon: View {
    let name: String
    let color: Color

    var body: some View {
        // SwiftUI's named lookup does not resolve these loose SwiftPM PNG resources.
        Image(nsImage: Bundle.module.image(forResource: NSImage.Name("sidebar-" + name))!)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 12, height: 12)
            .foregroundStyle(color)
    }
}
#endif

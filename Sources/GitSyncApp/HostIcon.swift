#if os(macOS)
import AppKit
import GitSyncCore
import SwiftUI
import UniformTypeIdentifiers

struct HostIcon: View {
    let hardware: HostHardware?

    static func macType(for model: String) -> UTType? {
        let type = UTType(tag: model, tagClass: UTTagClass(rawValue: "com.apple.device-model-code"), conformingTo: nil)
        return type?.isDeclared == true ? type : nil
    }

    var body: some View {
        Group {
            if hardware?.operatingSystem == "Linux", let type = Self.macType(for: "RackMount") {
                Image(nsImage: NSWorkspace.shared.icon(for: type))
                    .renderingMode(.original)
                    .resizable().scaledToFit()
            } else if hardware?.operatingSystem == "macOS", let model = hardware?.model,
                      let type = Self.macType(for: model) {
                Image(nsImage: NSWorkspace.shared.icon(for: type))
                    .renderingMode(.original)
                    .resizable().scaledToFit()
            } else {
                Image(systemName: "desktopcomputer")
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}
#endif

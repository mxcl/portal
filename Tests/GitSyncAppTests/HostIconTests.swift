#if os(macOS)
import Testing
import GitSyncCore
@testable import GitSyncApp

@Test("Mac model icons resolve through the system registry, with a fallback for unknown hardware")
@MainActor
func macModelIcons() {
    #expect(HostHardware.current.operatingSystem == "macOS")
    #expect(HostHardware.current.model?.isEmpty == false)
    #expect(HostIcon.macType(for: "Mac14,10")?.identifier == "com.apple.macbookpro-16-2023")
    #expect(HostIcon.macType(for: "unknown-model") == nil)
}
#endif

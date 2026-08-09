import Foundation
import Testing
@testable import PortalCore

@Suite("Portal command envelope")
struct PortalCommandEnvelopeTests {
    @Test("quotes commands and emits lifecycle markers")
    func envelope() {
        let script = PortalCommandEnvelope.shellScript(for: "printf '%s' hello")

        #expect(script.hasPrefix("\u{15}"))
        #expect(script.contains("__portal_cmd='printf '\\''%s'\\'' hello'"))
        #expect(script.contains(Data("printf '%s' hello".utf8).base64EncodedString()))
        #expect(script.contains("133;C"))
        #expect(script.contains("133;P"))
        #expect(script.contains("133;D"))
        #expect(script.hasSuffix("\n"))
    }

    @Test("can exit the shell with the command status after lifecycle markers")
    func exitingEnvelope() {
        let script = PortalCommandEnvelope.shellScript(
            for: "./example.cmd",
            exitsShellAfterCompletion: true
        )

        #expect(script.hasSuffix("printf '\\033]133;D;%s\\a' \"$__portal_status\"; exit \"$__portal_status\"\n"))
    }
}

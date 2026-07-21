import Foundation
import Testing
@testable import VaulttyCore

@Suite("Vaultty command envelope")
struct VaulttyCommandEnvelopeTests {
    @Test("quotes commands and emits lifecycle markers")
    func envelope() {
        let script = VaulttyCommandEnvelope.shellScript(for: "printf '%s' hello")

        #expect(script.hasPrefix("\u{15}"))
        #expect(script.contains("__vaultty_cmd='printf '\\''%s'\\'' hello'"))
        #expect(script.contains(Data("printf '%s' hello".utf8).base64EncodedString()))
        #expect(script.contains("133;C"))
        #expect(script.contains("133;P"))
        #expect(script.contains("133;D"))
        #expect(script.hasSuffix("\n"))
    }
}

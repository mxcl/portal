import Foundation
import Testing
@testable import VaulttyCore

@Suite("Vaultty block transcript")
struct VaulttyBlockTranscriptTests {
    @Test("reconstructs blocks when markers are split across network chunks")
    func splitMarkers() throws {
        var transcript = VaulttyBlockTranscript()
        let cwd = Data("/repo".utf8).base64EncodedString()
        let command = Data("printf 'hello'".utf8).base64EncodedString()

        transcript.consume("\u{1B}]133;R;\(cwd)\u{7}\u{1B}]13")
        transcript.consume("3;C;\(command)\u{7}hel")
        transcript.consume("lo\n\u{1B}]133;P;\(cwd)\u{7}\u{1B}]133;D;0\u{7}")

        let block = try #require(transcript.blocks.only)
        #expect(block.command == "printf 'hello'")
        #expect(block.cwd == "/repo")
        #expect(block.output == "hello\n")
        #expect(block.state == .completed(0))
    }

    @Test("strips styling and excludes alternate-screen contents")
    func terminalRendering() throws {
        var transcript = VaulttyBlockTranscript()
        let command = Data("less file".utf8).base64EncodedString()

        transcript.consume("\u{1B}]133;C;\(command)\u{7}")
        transcript.consume("before\n\u{1B}[31mred\u{1B}[0m\n")
        transcript.consume("\u{1B}[?1049heditor text")
        #expect(transcript.isAlternateScreenActive)
        transcript.consume("\u{1B}[?1049lafter\n\u{1B}]133;D;2\u{7}")

        let block = try #require(transcript.blocks.only)
        #expect(block.output == "before\nred\nafter\n")
        #expect(block.state == .completed(2))
        #expect(!transcript.isAlternateScreenActive)
    }

    @Test("a subsequent command closes an incomplete historical block")
    func incompleteHistory() throws {
        var transcript = VaulttyBlockTranscript()
        let first = Data("first".utf8).base64EncodedString()
        let second = Data("second".utf8).base64EncodedString()

        transcript.consume("\u{1B}]133;C;\(first)\u{7}one")
        transcript.consume("\u{1B}]133;C;\(second)\u{7}two")

        #expect(transcript.blocks.count == 2)
        #expect(transcript.blocks[0].state == .completed(-1))
        #expect(transcript.blocks[1].state == .running)
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}


import Foundation
import Testing
@testable import VaulttyCore

@Suite("Vaultty block transcript")
struct VaulttyBlockTranscriptTests {
    @Test("parser emits typed markers in order and resets partial input")
    func typedMarkers() {
        var parser = VaulttyMarkerParser()
        let cwd = Data("/repo\n".utf8).base64EncodedString()
        let command = Data("echo hi".utf8).base64EncodedString()

        #expect(parser.consume("before\u{1B}]133;R;\(cwd)\u{7}\u{1B}]13") == [
            .text("before"),
            .marker(VaulttyMarker(rawValue: "R;\(cwd)")),
        ])
        #expect(parser.consume("3;C;\(command)\u{7}\u{1B}]133;D;wat\u{7}") == [
            .marker(VaulttyMarker(rawValue: "C;\(command)")),
            .marker(VaulttyMarker(rawValue: "D;wat")),
        ])
        #expect(VaulttyMarker(rawValue: "R;\(cwd)").kind == .shellReady(cwd: "/repo"))
        #expect(VaulttyMarker(rawValue: "C;\(command)").kind == .commandStarted(command: "echo hi"))
        #expect(VaulttyMarker(rawValue: "P;bad").kind == .cwdChanged(nil))
        #expect(VaulttyMarker(rawValue: "D;wat").kind == .commandFinished(status: -1))
        #expect(VaulttyMarker(rawValue: "X;a;b").kind == .unknown(code: "X", payload: "a;b"))

        _ = parser.consume("\u{1B}]133;C;partial")
        parser.reset()
        #expect(parser.consume("visible") == [.text("visible")])
    }

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

    @Test("carriage returns replace progress output instead of accumulating it")
    func carriageReturnProgress() throws {
        var transcript = VaulttyBlockTranscript()
        let command = Data("git pull".utf8).base64EncodedString()

        transcript.consume("\u{1B}]133;C;\(command)\u{7}")
        transcript.consume("remote: Counting objects\r\n")
        #expect(transcript.blocks.only?.output == "remote: Counting objects\n")
        transcript.consume("Receiving objects: 10%\r")
        #expect(
            transcript.blocks.only?.output ==
                "remote: Counting objects\nReceiving objects: 10%"
        )
        transcript.consume("\u{1B}[2KReceiving objects: 50%\rReceiving objects: 100%\nDone\n")
        transcript.consume("\u{1B}]133;D;0\u{7}")

        let block = try #require(transcript.blocks.only)
        #expect(block.output == "remote: Counting objects\nReceiving objects: 100%\nDone\n")
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

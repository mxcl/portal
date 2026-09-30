#if os(macOS)
import AppKit
import Testing
@testable import PortalTerminal

@Suite("Embedded terminal", .serialized)
struct TerminalIntegrationTests {
    @Test @MainActor func tabBarStartsHidden() {
        let controller = TerminalViewController()
        #expect(!controller.isTabSession)
        controller.enterTabSession()
        #expect(controller.isTabSession)
        #expect(!controller.isViewLoaded)
    }

    @Test @MainActor func rendererAndCompletions() {
        Ansi.runSelfTests()
        #expect(Ansi.terminalScreenScrollRegionSelfTest())
        #expect(Ansi.terminalScreenFixedHeightSelfTest())
        #expect(Ansi.terminalScreenDeferredWrapSelfTest())
        #expect(TerminalOutputProcessor.alternateScreenTranscriptSelfTest())
        #expect(TerminalOutputProcessor.terminalSizeProbeSelfTest())
        #expect(TerminalOutputProcessor.terminalResponsesAreImmediateSelfTest())
        #expect(TerminalOutputProcessor.inputFeedbackPrioritySelfTest())
        #expect(TerminalOutputProcessor.truncatedHistoryReplaySelfTest())
        #expect(PortalCompletionEngine.calculatorCompletionSelfTest())
        #expect(PortalCompletionEngine.historyMergePrefixSelfTest())
        #expect(ShellCompletionParser.midTokenReplacementRangeSelfTest())
    }

    @Test @MainActor func terminalColorsFollowAppearance() throws {
        let output = Ansi.StyledTextRenderer().process("\u{1B}[93mY\u{1B}[38;2;12;34;56mR").attributedText
        let yellow = try #require(output.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let rgb = try #require(output.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor)
        var colors: [NSColor] = []
        var surfaces: [NSColor] = []
        var explicitColors: [NSColor] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                colors.append(yellow.usingColorSpace(.sRGB)!)
                surfaces.append(TahoeGlassPalette.commandBackground.usingColorSpace(.sRGB)!)
                explicitColors.append(rgb.usingColorSpace(.sRGB)!)
            }
        }
        #expect(colors[0].greenComponent < 0.5)
        #expect(colors[1].greenComponent > 0.9)
        #expect(surfaces.allSatisfy { $0.alphaComponent == 1 })
        #expect(surfaces[0].redComponent > 0.95)
        #expect(surfaces[1].redComponent < 0.25)
        #expect(explicitColors[0] == explicitColors[1])
    }

    @Test func processExitDrainsOutput() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf 'READY 0\\nEXIT 0\\n'"]
        let queue = DispatchQueue(label: "terminal-exit-test")
        let transport = ProcessSessionTransport(queue: queue, process: process, write: { _, _ in })
        let output = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            queue.async {
                var output = ""
                transport.onText = { output += $0 }
                transport.onExit = { _ in continuation.resume(returning: output) }
                do { try transport.start() }
                catch { continuation.resume(throwing: error) }
            }
        }
        transport.close(terminate: false)
        #expect(output == "READY 0\nEXIT 0\n")
    }

    @Test func reconnectNeverStartsAnotherShell() {
        let current = PtySession.reattachCommand(version: 2, clientID: "client", sessionID: "session")
        #expect(SessionWireProtocol.encode(current) == "JOIN2 2 mac Y2xpZW50 c2Vzc2lvbg==")
        let previous = SessionWireProtocol.encode(PtySession.reattachCommand(version: 1, clientID: "client", sessionID: "session"))
        let fields = previous.split(separator: " ")
        #expect(String(data: Data(base64Encoded: String(fields[3]))!, encoding: .utf8) == "/usr/bin/false")
    }

    @Test func historyRetainsMarkersAcrossChunkSplits() {
        let stream = "before\u{1B}]133;C;ZWNobyBoaQ==\u{7}hi\n\u{1B}]133;D;0\u{7}"
        for split in 0...stream.count {
            var parser = PortalMarkerParser()
            let events = parser.consume(String(stream.prefix(split))) + parser.consume(String(stream.dropFirst(split)))
            let markers = events.compactMap { event -> PortalMarker.Kind? in
                if case .marker(let marker) = event { return marker.kind }; return nil
            }
            #expect(markers == [.commandStarted(command: "echo hi"), .commandFinished(status: 0)])
        }
        #expect(TerminalHistory.normalizedReplay(" 0% [---]\nlog\n\u{1B}]133;C;") == "log\n\u{1B}]133;C;")
    }
}

#endif

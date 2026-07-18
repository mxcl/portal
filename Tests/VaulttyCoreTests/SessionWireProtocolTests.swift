import Foundation
import Testing
@testable import VaulttyCore

@Suite("Session wire protocol")
struct SessionWireProtocolTests {
    @Test("attach encoding is deterministic and round-trippable")
    func attachEncoding() throws {
        let line = SessionWireProtocol.encode(.attach(
            sessionID: "session",
            workingDirectory: "/tmp/repo",
            shellPath: "/bin/zsh",
            environment: ["Z": "last", "A": "first"]
        ))
        let fields = line.split(separator: " ").map(String.init)

        #expect(fields.first == "ATTACH")
        #expect(try decode(fields[1]) == "session")
        #expect(try decode(fields[2]) == "/tmp/repo")
        #expect(try decode(fields[3]) == "/bin/zsh")
        #expect(try decode(fields[4]) == "A=first\0Z=last")
    }

    @Test("client commands use one encoder")
    func clientCommands() {
        #expect(SessionWireProtocol.encode(.resize(rows: 24, cols: 80)) == "RESIZE 24 80")
        #expect(SessionWireProtocol.encode(.interrupt) == "INTERRUPT")
        #expect(SessionWireProtocol.encode(.clearHistory) == "CLEAR_HISTORY")
        #expect(SessionWireProtocol.encode(.input(Data("hi".utf8))) == "INPUT aGk=")
        #expect(SessionWireProtocol.encode(.state(Data("{}".utf8))) == "STATE e30=")
        #expect(SessionWireProtocol.encode(.list) == "LIST")
        #expect(SessionWireProtocol.encode(.kill(sessionID: "id")) == "KILL aWQ=")
    }

    @Test("decoder buffers partial lines and preserves event order")
    func streamingDecoder() throws {
        var decoder = SessionWireProtocol.Decoder()
        #expect(decoder.append("READY ").isEmpty)
        let events = decoder.append("0\nHISTORY aGlzdG9yeQ==\nOUTPUT bGl2ZQ==\nEXIT 7\n")
        #expect(events.count == 4)
        guard case .ready(created: false) = events[0] else {
            Issue.record("Expected READY")
            return
        }
        guard case .history("history") = events[1] else {
            Issue.record("Expected HISTORY")
            return
        }
        guard case .output("live") = events[2] else {
            Issue.record("Expected OUTPUT")
            return
        }
        guard case .exit(7) = events[3] else {
            Issue.record("Expected EXIT")
            return
        }
    }

    @Test("sessions response decodes through the same server decoder")
    func sessionsResponse() throws {
        let payload = Data("[{\"sessionID\":\"one\"}]".utf8)
        let event = SessionWireProtocol.Decoder.decode("SESSIONS \(payload.base64EncodedString())")
        guard case .sessions(let decoded) = event else {
            Issue.record("Expected SESSIONS")
            return
        }
        #expect(decoded == payload)
    }

    @Test("unknown and malformed lines remain observable")
    func unknownLines() {
        guard case .unknown("OUTPUT invalid") = SessionWireProtocol.Decoder.decode("OUTPUT invalid") else {
            Issue.record("Expected malformed output to remain unknown")
            return
        }
    }

    private func decode(_ value: String) throws -> String {
        let data = try #require(Data(base64Encoded: value))
        return try #require(String(data: data, encoding: .utf8))
    }
}

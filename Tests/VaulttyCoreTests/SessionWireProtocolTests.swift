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
        #expect(SessionWireProtocol.encode(.killAttachedSession) == "KILL")
        #expect(SessionWireProtocol.encode(.historyPage(beforeSequence: 42, maxLines: 1000)) == "HISTORY_PAGE 42 1000")
        #expect(SessionWireProtocol.encode(.joinV2(version: 2, role: .phone, clientID: "p", sessionID: "s")) == "JOIN2 2 phone cA== cw==")
    }

    @Test("v2 attach identifies protocol, role, and client")
    func attachV2Encoding() {
        let line = SessionWireProtocol.encode(.attachV2(
            version: 2,
            role: .phone,
            clientID: "phone-1",
            sessionID: "session",
            workingDirectory: "/tmp",
            shellPath: "/bin/zsh",
            environment: [:]
        ))
        let fields = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        #expect(fields[0...2] == ["ATTACH2", "2", "phone"])
        #expect(fields.count == 8)
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

    @Test("v2 decoder exposes canonical snapshots and ordered deltas")
    func v2Events() {
        let snapshot = SessionWireProtocol.Decoder.decode("SNAPSHOT 9 24 80 \(Data("screen".utf8).base64EncodedString())")
        guard case .snapshot(sequence: 9, rows: 24, cols: 80, contents: "screen") = snapshot else {
            Issue.record("Expected canonical snapshot")
            return
        }
        let output = SessionWireProtocol.Decoder.decode("OUTPUT2 10 \(Data("delta".utf8).base64EncodedString())")
        guard case .sequencedOutput(sequence: 10, text: "delta") = output else {
            Issue.record("Expected sequenced output")
            return
        }
        let page = SessionWireProtocol.Decoder.decode("HISTORY_PAGE 2 9 1 \(Data("older".utf8).base64EncodedString())")
        guard case .historyPage(startSequence: 2, endSequence: 9, hasOlder: true, text: "older") = page else {
            Issue.record("Expected history page")
            return
        }
        guard case .presence(2) = SessionWireProtocol.Decoder.decode("PRESENCE 2") else {
            Issue.record("Expected presence")
            return
        }
        guard case .geometry(rows: 30, cols: 100) = SessionWireProtocol.Decoder.decode("GEOMETRY 30 100") else {
            Issue.record("Expected geometry")
            return
        }
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

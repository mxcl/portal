import Foundation

enum SessionWireProtocol {
    static let currentVersion: UInt16 = 2
    static let previousVersion: UInt16 = 1
    // v2 readers ship before Mac clients make v2 their default write format.
    static let macWriteVersion: UInt16 = 1

    enum ClientRole: String {
        case mac
        case phone
    }

    enum ClientCommand {
        case attach(
            sessionID: String,
            workingDirectory: String,
            shellPath: String,
            environment: [String: String]
        )
        case attachV2(
            version: UInt16,
            role: ClientRole,
            clientID: String,
            sessionID: String,
            workingDirectory: String,
            shellPath: String,
            environment: [String: String]
        )
        case joinV2(version: UInt16, role: ClientRole, clientID: String, sessionID: String)
        case resize(rows: UInt16, cols: UInt16)
        case interrupt
        case clearHistory
        case input(Data)
        case state(Data)
        case list
        case kill(sessionID: String)
        case killAttachedSession
        case historyPage(beforeSequence: UInt64, maxLines: UInt16)
        case supportedProtocols
    }

    enum ServerEvent {
        case output(String)
        case sequencedOutput(sequence: UInt64, text: String)
        case history(String)
        case historyPage(startSequence: UInt64, endSequence: UInt64, hasOlder: Bool, text: String)
        case snapshot(sequence: UInt64, rows: UInt16, cols: UInt16, contents: String)
        case protocolVersion(UInt16)
        case supportedProtocols([UInt16])
        case presence(Int)
        case geometry(rows: UInt16, cols: UInt16)
        case notFound
        case ready(created: Bool)
        case exit(Int32)
        case sessions(Data)
        case unknown(String)
    }

    struct Decoder {
        private var buffer = ""

        mutating func append(_ text: String) -> [ServerEvent] {
            buffer += text
            guard text.contains("\n") else { return [] }
            var events: [ServerEvent] = []
            while let newline = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<newline]).trimmingCharacters(in: .newlines)
                buffer.removeSubrange(...newline)
                events.append(Self.decode(line))
            }
            return events
        }

        mutating func reset() {
            buffer.removeAll(keepingCapacity: false)
        }

        static func decode(_ line: String) -> ServerEvent {
            if let fields = fields(prefix: "OUTPUT2 ", line: line, count: 2),
               let sequence = UInt64(fields[0]),
               let text = decodeBase64Text(fields[1]) {
                return .sequencedOutput(sequence: sequence, text: text)
            }
            if let fields = fields(prefix: "SNAPSHOT ", line: line, count: 4),
               let sequence = UInt64(fields[0]),
               let rows = UInt16(fields[1]),
               let cols = UInt16(fields[2]),
               let contents = decodeBase64Text(fields[3]) {
                return .snapshot(sequence: sequence, rows: rows, cols: cols, contents: contents)
            }
            if let fields = fields(prefix: "HISTORY_PAGE ", line: line, count: 4),
               let start = UInt64(fields[0]),
               let end = UInt64(fields[1]),
               let text = decodeBase64Text(fields[3]) {
                return .historyPage(
                    startSequence: start,
                    endSequence: end,
                    hasOlder: fields[2] == "1",
                    text: text
                )
            }
            if let value = line.removingPrefix("PROTOCOL "), let version = UInt16(value) {
                return .protocolVersion(version)
            }
            if let value = line.removingPrefix("PROTOCOLS ") {
                let versions = value.split(separator: " ").compactMap { UInt16($0) }
                if !versions.isEmpty {
                    return .supportedProtocols(versions)
                }
            }
            if let value = line.removingPrefix("PRESENCE "), let count = Int(value) {
                return .presence(count)
            }
            if let values = fields(prefix: "GEOMETRY ", line: line, count: 2),
               let rows = UInt16(values[0]),
               let cols = UInt16(values[1]) {
                return .geometry(rows: rows, cols: cols)
            }
            if line == "NOT_FOUND" {
                return .notFound
            }
            if let text = decodeText(prefix: "OUTPUT ", line: line) {
                return .output(text)
            }
            if let text = decodeText(prefix: "HISTORY ", line: line) {
                return .history(text)
            }
            if let value = line.removingPrefix("READY ") {
                return .ready(created: value.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
            }
            if let value = line.removingPrefix("EXIT ") {
                return .exit(Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1)
            }
            if let value = line.removingPrefix("SESSIONS "), let data = Data(base64Encoded: value) {
                return .sessions(data)
            }
            return .unknown(line)
        }

        private static func decodeText(prefix: String, line: String) -> String? {
            guard let payload = line.removingPrefix(prefix) else { return nil }
            return decodeBase64Text(payload)
        }

        private static func decodeBase64Text(_ payload: String) -> String? {
            guard let data = Data(base64Encoded: payload) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        private static func fields(prefix: String, line: String, count: Int) -> [String]? {
            guard let payload = line.removingPrefix(prefix) else { return nil }
            let fields = payload.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            return fields.count == count ? fields : nil
        }
    }

    static func encode(_ command: ClientCommand) -> String {
        switch command {
        case .attach(let sessionID, let workingDirectory, let shellPath, let environment):
            let environmentBlob = environment
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: "\0")
            return [
                "ATTACH",
                base64(sessionID),
                base64(workingDirectory),
                base64(shellPath),
                environmentBlob.isEmpty ? "-" : base64(environmentBlob)
            ].joined(separator: " ")
        case .attachV2(
            let version,
            let role,
            let clientID,
            let sessionID,
            let workingDirectory,
            let shellPath,
            let environment
        ):
            let environmentBlob = environment
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: "\0")
            return [
                "ATTACH2",
                String(version),
                role.rawValue,
                base64(clientID),
                base64(sessionID),
                base64(workingDirectory),
                base64(shellPath),
                base64(environmentBlob)
            ].joined(separator: " ")
        case .joinV2(let version, let role, let clientID, let sessionID):
            return [
                "JOIN2",
                String(version),
                role.rawValue,
                base64(clientID),
                base64(sessionID)
            ].joined(separator: " ")
        case .resize(let rows, let cols):
            return "RESIZE \(rows) \(cols)"
        case .interrupt:
            return "INTERRUPT"
        case .clearHistory:
            return "CLEAR_HISTORY"
        case .input(let data):
            return "INPUT \(data.base64EncodedString())"
        case .state(let data):
            return "STATE \(data.base64EncodedString())"
        case .list:
            return "LIST"
        case .kill(let sessionID):
            return "KILL \(base64(sessionID))"
        case .killAttachedSession:
            return "KILL"
        case .historyPage(let beforeSequence, let maxLines):
            return "HISTORY_PAGE \(beforeSequence) \(maxLines)"
        case .supportedProtocols:
            return "PROTOCOLS"
        }
    }

    static func highestMutualVersion(peerVersions: [UInt16]) -> UInt16? {
        peerVersions
            .filter { previousVersion...currentVersion ~= $0 }
            .max()
    }

    static func macAttachVersion(peerVersions: [UInt16]) -> UInt16? {
        highestMutualVersion(peerVersions: peerVersions).map { min($0, macWriteVersion) }
    }

    static func versions(fromCapability line: String) -> [UInt16]? {
        guard let value = line.removingPrefix("session-wire=") else { return nil }
        let versions = value.split(separator: ",").compactMap { UInt16($0) }
        return versions.isEmpty ? nil : versions
    }

    static func localBridgeCandidates(forExecutable executablePath: String) -> [String] {
        let executable = URL(fileURLWithPath: executablePath)
        guard ["portal-remote-agent", "vaultty-remote-agent"].contains(executable.lastPathComponent)
        else { return [] }
        let directory = executable.deletingLastPathComponent()
        return ["vaultty-session-bridge", "portal-session-bridge"].map {
            directory.appendingPathComponent($0).path
        }
    }

    private static func base64(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

import Foundation

enum SessionWireProtocol {
    enum ClientCommand {
        case attach(
            sessionID: String,
            workingDirectory: String,
            shellPath: String,
            environment: [String: String]
        )
        case resize(rows: UInt16, cols: UInt16)
        case interrupt
        case clearHistory
        case input(Data)
        case state(Data)
        case list
        case kill(sessionID: String)
    }

    enum ServerEvent {
        case output(String)
        case history(String)
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
            guard let payload = line.removingPrefix(prefix),
                  let data = Data(base64Encoded: payload),
                  let text = String(data: data, encoding: .utf8)
            else { return nil }
            return text
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
                base64(environmentBlob)
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

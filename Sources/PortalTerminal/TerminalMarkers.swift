#if os(macOS)
import Foundation

enum TerminalHistory {
    static func normalizedReplay(_ text: String) -> String {
        guard text.contains("%") else { return text }
        var parser = PortalMarkerParser()
        let events = parser.consume(text)
        return events.map { event in
            switch event {
            case .text(let output): removingTransientProgressLines(output)
            case .marker(let marker): "\u{1B}]133;" + marker.rawValue + "\u{7}"
            }
        }.joined() + parser.continuation
    }

    private static func removingTransientProgressLines(_ text: String) -> String {
        guard text.contains("%") else { return text }
        let lines = text.components(separatedBy: "\n")
        return lines.enumerated().map { index, line in
            guard index < lines.count - 1 else { return line }
            let visible = line.replacingOccurrences(
                of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            // ponytail: only pure SwiftPM bars; leave other output and cursor controls intact.
            if visible.range(of: #"^(100|[0-9]{1,2})% \[[-=]+\]$"#,
                             options: .regularExpression) != nil {
                return ""
            }
            return line + "\n"
        }.joined()
    }

}

struct PortalMarker: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case shellReady(cwd: String?)
        case commandStarted(command: String)
        case cwdChanged(String?)
        case openRemoteCode(payload: String)
        case commandFinished(status: Int32)
        case unknown(code: String, payload: String)
    }

    let rawValue: String
    let kind: Kind

    init(rawValue: String) {
        self.rawValue = rawValue
        let fields = rawValue.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        let code = fields.first.map(String.init) ?? ""
        let payload = fields.count > 1 ? String(fields[1]) : ""
        switch code {
        case "R":
            kind = .shellReady(cwd: Self.decode(payload))
        case "C":
            kind = .commandStarted(command: Self.decode(payload) ?? "")
        case "P":
            kind = .cwdChanged(Self.decode(payload))
        case "O":
            kind = .openRemoteCode(payload: payload)
        case "D":
            kind = .commandFinished(
                status: Int32(payload.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            )
        default:
            kind = .unknown(code: code, payload: payload)
        }
    }

    private static func decode(_ value: String) -> String? {
        guard let data = Data(base64Encoded: value),
              let decoded = String(data: data, encoding: .utf8)
        else { return nil }
        return decoded.trimmingCharacters(in: .newlines)
    }
}

struct PortalMarkerParser: Sendable {
    enum Event: Equatable, Sendable {
        case text(String)
        case marker(PortalMarker)
    }

    private static let prefix = "\u{1B}]133;"
    private var buffer = ""

    fileprivate var continuation: String { buffer }

    init() {}

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    mutating func consume(_ text: String) -> [Event] {
        buffer += text
        var events: [Event] = []

        while true {
            guard let start = buffer.range(of: Self.prefix) else {
                let retained = trailingPrefixLength(in: buffer)
                let split = buffer.index(buffer.endIndex, offsetBy: -retained)
                appendText(String(buffer[..<split]), to: &events)
                buffer = String(buffer[split...])
                break
            }

            appendText(String(buffer[..<start.lowerBound]), to: &events)
            buffer.removeSubrange(..<start.lowerBound)
            guard let end = buffer.firstIndex(of: "\u{7}") else { break }
            let markerStart = buffer.index(buffer.startIndex, offsetBy: Self.prefix.count)
            events.append(.marker(PortalMarker(
                rawValue: String(buffer[markerStart..<end])
            )))
            buffer.removeSubrange(...end)
        }
        return events
    }

    private func trailingPrefixLength(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        for length in stride(from: Self.prefix.count - 1, through: 1, by: -1) {
            if text.hasSuffix(Self.prefix.prefix(length)) { return length }
        }
        return 0
    }

    private func appendText(_ text: String, to events: inout [Event]) {
        guard !text.isEmpty else { return }
        if case .text(let existing) = events.last {
            events[events.count - 1] = .text(existing + text)
        } else {
            events.append(.text(text))
        }
    }
}

#endif

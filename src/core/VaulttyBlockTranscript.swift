import Foundation

public struct VaulttyBlock: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case running
        case completed(Int32)
    }

    public let id: UUID
    public let command: String
    public let cwd: String?
    public fileprivate(set) var output: String
    public fileprivate(set) var state: State

    public init(
        id: UUID = UUID(),
        command: String,
        cwd: String?,
        output: String = "",
        state: State = .running
    ) {
        self.id = id
        self.command = command
        self.cwd = cwd
        self.output = output
        self.state = state
    }
}

/// Reconstructs Vaultty's command blocks from the OSC 133 stream retained by a session.
public struct VaulttyBlockTranscript: Sendable {
    public private(set) var blocks: [VaulttyBlock] = []
    public private(set) var isAlternateScreenActive = false
    public private(set) var revision: UInt64 = 0

    private var parser = VaulttyMarkerParser()
    private var renderer = PlainTerminalRenderer()
    private var currentCwd: String?
    private var activeBlockIndex: Int?

    public init() {}

    public mutating func reset() {
        self = Self()
    }

    public mutating func consume(_ text: String) {
        for event in parser.consume(text) {
            switch event {
            case .text(let visible):
                let rendered = renderer.consume(visible)
                isAlternateScreenActive = renderer.isAlternateScreenActive
                guard let activeBlockIndex, !rendered.isEmpty else { continue }
                blocks[activeBlockIndex].output += rendered
                revision &+= 1
            case .marker(let marker):
                consume(marker)
            }
        }
    }

    private mutating func consume(_ marker: VaulttyMarker) {
        switch marker.kind {
        case .shellReady(let cwd):
            currentCwd = cwd
        case .cwdChanged(let cwd):
            currentCwd = cwd
        case .commandStarted(let command):
            if let activeBlockIndex,
               case .running = blocks[activeBlockIndex].state {
                blocks[activeBlockIndex].state = .completed(-1)
            }
            renderer.resetOutputState()
            blocks.append(VaulttyBlock(command: command, cwd: currentCwd))
            activeBlockIndex = blocks.indices.last
            revision &+= 1
        case .commandFinished(let status):
            guard let activeBlockIndex else { return }
            blocks[activeBlockIndex].state = .completed(status)
            self.activeBlockIndex = nil
            revision &+= 1
        case .openRemoteCode, .unknown:
            break
        }
    }
}

public struct VaulttyMarker: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case shellReady(cwd: String?)
        case commandStarted(command: String)
        case cwdChanged(String?)
        case openRemoteCode(payload: String)
        case commandFinished(status: Int32)
        case unknown(code: String, payload: String)
    }

    public let rawValue: String
    public let kind: Kind

    public init(rawValue: String) {
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

public struct VaulttyMarkerParser: Sendable {
    public enum Event: Equatable, Sendable {
        case text(String)
        case marker(VaulttyMarker)
    }

    private static let prefix = "\u{1B}]133;"
    private var buffer = ""

    public init() {}

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    public mutating func consume(_ text: String) -> [Event] {
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
            events.append(.marker(VaulttyMarker(
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

private struct PlainTerminalRenderer: Sendable {
    private enum State: Sendable {
        case text
        case escape
        case csi(String)
        case osc
        case oscEscape
    }

    private var state: State = .text
    private(set) var isAlternateScreenActive = false

    mutating func resetOutputState() {
        state = .text
        isAlternateScreenActive = false
    }

    mutating func consume(_ text: String) -> String {
        var output = ""
        for scalar in text.unicodeScalars {
            switch state {
            case .text:
                switch scalar.value {
                case 0x1B: state = .escape
                case 0x0A where !isAlternateScreenActive,
                     0x09 where !isAlternateScreenActive:
                    output.unicodeScalars.append(scalar)
                case 0x20...0x7E where !isAlternateScreenActive,
                     0xA0...UInt32.max where !isAlternateScreenActive:
                    output.unicodeScalars.append(scalar)
                default: break
                }
            case .escape:
                if scalar == "[" {
                    state = .csi("")
                } else if scalar == "]" {
                    state = .osc
                } else {
                    state = .text
                }
            case .csi(var body):
                body.unicodeScalars.append(scalar)
                if (0x40...0x7E).contains(scalar.value) {
                    if body == "?1049h" || body == "?1047h" || body == "?47h" {
                        isAlternateScreenActive = true
                    } else if body == "?1049l" || body == "?1047l" || body == "?47l" {
                        isAlternateScreenActive = false
                    }
                    state = .text
                } else {
                    state = .csi(body)
                }
            case .osc:
                if scalar.value == 0x07 {
                    state = .text
                } else if scalar.value == 0x1B {
                    state = .oscEscape
                }
            case .oscEscape:
                state = scalar == "\\" ? .text : .osc
            }
        }
        return output
    }
}

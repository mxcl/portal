import Foundation

struct RemoteCatalog: Codable, Equatable, Sendable {
    static let currentVersion: UInt16 = 1

    var version: UInt16 = currentVersion
    var generatedAt: Date
    var macs: [RemoteMac]
}

struct RemoteMac: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var online: Bool
    var sessions: [RemoteCatalogSession]
}

struct RemoteCatalogSession: Codable, Equatable, Identifiable, Sendable {
    var id: String { sessionID }
    var sessionID: String
    var title: String
    var cwd: String
    var createdAt: Date
    var commandCount: Int
    var runningCommand: String?
    var attachedClientCount: Int
}

enum RemoteMessageKind: String, Codable, Sendable {
    case catalog
    case attach
    case detach
    case input
    case interrupt
    case historyPage
    case terminalEvent
    case error
}

struct RemoteMessage: Codable, Equatable, Sendable {
    static let currentVersion: UInt16 = 1

    var version: UInt16 = currentVersion
    var kind: RemoteMessageKind
    var requestID: String
    var macID: String?
    var sessionID: String?
    var sequence: UInt64?
    var payload: Data?
}

enum RemoteSequenceResult: Equatable, Sendable {
    case accepted
    case duplicate
    case gap(expected: UInt64)
}

struct RemoteSequenceTracker: Sendable {
    private(set) var lastSequence: UInt64?

    mutating func accept(_ sequence: UInt64) -> RemoteSequenceResult {
        guard let lastSequence else {
            self.lastSequence = sequence
            return .accepted
        }
        if sequence <= lastSequence {
            return .duplicate
        }
        let expected = lastSequence.saturatingAdding(1)
        guard sequence == expected else {
            return .gap(expected: expected)
        }
        self.lastSequence = sequence
        return .accepted
    }

    mutating func reset(to sequence: UInt64?) {
        lastSequence = sequence
    }
}

private extension UInt64 {
    func saturatingAdding(_ value: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(value)
        return overflow ? .max : sum
    }
}


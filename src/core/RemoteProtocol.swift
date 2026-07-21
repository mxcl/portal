import Foundation

public struct RemoteCatalog: Codable, Equatable, Sendable {
    public static let currentVersion: UInt16 = 1

    public var version: UInt16 = currentVersion
    public var generatedAt: Date
    public var macs: [RemoteMac]

    public init(version: UInt16 = currentVersion, generatedAt: Date, macs: [RemoteMac]) {
        self.version = version
        self.generatedAt = generatedAt
        self.macs = macs
    }
}

public struct RemoteMac: Codable, Equatable, Identifiable, Sendable {
    public static let createSessionCapability = "create-session"

    public var id: String
    public var name: String
    public var online: Bool
    public var lastSeen: Date
    public var sessions: [RemoteCatalogSession]
    public var capabilities: Set<String>?

    public init(
        id: String,
        name: String,
        online: Bool,
        lastSeen: Date = Date(),
        sessions: [RemoteCatalogSession],
        capabilities: Set<String>? = nil
    ) {
        self.id = id
        self.name = name
        self.online = online
        self.lastSeen = lastSeen
        self.sessions = sessions
        self.capabilities = capabilities
    }

    public var supportsSessionCreation: Bool {
        capabilities?.contains(Self.createSessionCapability) == true
    }
}

public struct RemoteCatalogSession: Codable, Equatable, Identifiable, Sendable {
    public var id: String { sessionID }
    public var sessionID: String
    public var title: String
    public var cwd: String
    public var createdAt: Date
    public var commandCount: Int
    public var runningCommand: String?
    public var attachedClientCount: Int

    public init(sessionID: String, title: String, cwd: String, createdAt: Date, commandCount: Int, runningCommand: String?, attachedClientCount: Int) {
        self.sessionID = sessionID
        self.title = title
        self.cwd = cwd
        self.createdAt = createdAt
        self.commandCount = commandCount
        self.runningCommand = runningCommand
        self.attachedClientCount = attachedClientCount
    }
}

public enum RemoteMessageKind: String, Codable, Sendable {
    case catalog
    case attach
    case detach
    case createSession
    case sessionCreated
    case input
    case submit
    case interrupt
    case historyPage
    case terminalEvent
    case presence
    case error
}

public struct RemoteMessage: Codable, Equatable, Sendable {
    public static let currentVersion: UInt16 = 1

    public var version: UInt16 = currentVersion
    public var kind: RemoteMessageKind
    public var requestID: String
    public var macID: String?
    public var sessionID: String?
    public var sequence: UInt64?
    public var payload: Data?

    public init(version: UInt16 = currentVersion, kind: RemoteMessageKind, requestID: String, macID: String? = nil, sessionID: String? = nil, sequence: UInt64? = nil, payload: Data? = nil) {
        self.version = version
        self.kind = kind
        self.requestID = requestID
        self.macID = macID
        self.sessionID = sessionID
        self.sequence = sequence
        self.payload = payload
    }
}

public enum RemoteSequenceResult: Equatable, Sendable {
    case accepted
    case duplicate
    case gap(expected: UInt64)
}

public struct RemoteSequenceTracker: Sendable {
    public private(set) var lastSequence: UInt64?

    public init() {}

    public mutating func accept(_ sequence: UInt64) -> RemoteSequenceResult {
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

    public mutating func reset(to sequence: UInt64?) {
        lastSequence = sequence
    }
}

private extension UInt64 {
    func saturatingAdding(_ value: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(value)
        return overflow ? .max : sum
    }
}

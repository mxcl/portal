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

    public mutating func record(_ session: RemoteCatalogSession, onMac macID: String) {
        guard let macIndex = macs.firstIndex(where: { $0.id == macID }) else { return }
        if let sessionIndex = macs[macIndex].sessions.firstIndex(where: {
            $0.sessionID == session.sessionID
        }) {
            macs[macIndex].sessions[sessionIndex] = session
        } else {
            macs[macIndex].sessions.append(session)
        }
    }
}

public struct RemoteMac: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var online: Bool
    public var lastSeen: Date
    public var homeDirectory: String?
    public var sessions: [RemoteCatalogSession]

    public init(
        id: String,
        name: String,
        online: Bool,
        lastSeen: Date = Date(),
        homeDirectory: String? = nil,
        sessions: [RemoteCatalogSession]
    ) {
        self.id = id
        self.name = name
        self.online = online
        self.lastSeen = lastSeen
        self.homeDirectory = homeDirectory
        self.sessions = sessions
    }
}

public enum RemoteClientRole: String, Codable, Equatable, Sendable {
    case phone
    case mac
}

public struct RemoteCapabilities: Codable, Equatable, Sendable {
    public static let relayCompletion = "relay-completion-v1"

    public var values: [String]

    public init(values: [String]) {
        self.values = values
    }
}

public enum RemoteCompletionOperation: String, Codable, CaseIterable, Sendable {
    case completeCommands = "complete-commands"
    case completePath = "complete-path"
    case runGenerator = "run-generator"
}

public struct RemoteCompletionRequest: Codable, Equatable, Sendable {
    public static let maximumPayloadSize = 128 * 1024

    public var operationID: String
    public var operation: RemoteCompletionOperation
    public var payload: Data

    public init(operationID: String, operation: RemoteCompletionOperation, payload: Data) {
        self.operationID = operationID
        self.operation = operation
        self.payload = payload
    }
}

public struct RemoteCompletionResponse: Codable, Equatable, Sendable {
    public static let maximumPayloadSize = 768 * 1024

    public var operationID: String
    public var payload: Data?
    public var error: String?

    public init(operationID: String, payload: Data? = nil, error: String? = nil) {
        self.operationID = operationID
        self.payload = payload
        self.error = error
    }
}

public struct RemoteCompletionCancellation: Codable, Equatable, Sendable {
    public var operationID: String

    public init(operationID: String) {
        self.operationID = operationID
    }
}

public struct RemoteTerminalSize: Codable, Equatable, Sendable {
    public var rows: UInt16
    public var cols: UInt16

    public init(rows: UInt16, cols: UInt16) {
        self.rows = rows
        self.cols = cols
    }
}

public struct RemoteTerminalSnapshot: Codable, Equatable, Sendable {
    public var rows: UInt16
    public var cols: UInt16
    public var contents: Data

    public init(rows: UInt16, cols: UInt16, contents: Data) {
        self.rows = rows
        self.cols = cols
        self.contents = contents
    }
}

public struct RemoteSessionState: Codable, Equatable, Sendable {
    public var title: String
    public var cwd: String
    public var createdAt: Date
    public var commandCount: Int
    public var runningCommand: String?
    public var commandHistory: [String]

    public init(
        title: String,
        cwd: String,
        createdAt: Date,
        commandCount: Int,
        runningCommand: String?,
        commandHistory: [String]
    ) {
        self.title = title
        self.cwd = cwd
        self.createdAt = createdAt
        self.commandCount = commandCount
        self.runningCommand = runningCommand
        self.commandHistory = commandHistory
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

public enum RemoteMessageKind: Codable, Equatable, Sendable {
    case catalog
    case attach
    case detach
    case createSession
    case sessionCreated
    case input
    case submit
    case interrupt
    case resize
    case clearHistory
    case updateState
    case kill
    case historyPage
    case terminalSnapshot
    case terminalEvent
    case presence
    case capabilities
    case completionRequest
    case completionResponse
    case completionCancel
    case error
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = switch value {
        case "catalog": .catalog
        case "attach": .attach
        case "detach": .detach
        case "createSession": .createSession
        case "sessionCreated": .sessionCreated
        case "input": .input
        case "submit": .submit
        case "interrupt": .interrupt
        case "resize": .resize
        case "clearHistory": .clearHistory
        case "updateState": .updateState
        case "kill": .kill
        case "historyPage": .historyPage
        case "terminalSnapshot": .terminalSnapshot
        case "terminalEvent": .terminalEvent
        case "presence": .presence
        case "capabilities": .capabilities
        case "completionRequest": .completionRequest
        case "completionResponse": .completionResponse
        case "completionCancel": .completionCancel
        case "error": .error
        default: .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        let value = switch self {
        case .catalog: "catalog"
        case .attach: "attach"
        case .detach: "detach"
        case .createSession: "createSession"
        case .sessionCreated: "sessionCreated"
        case .input: "input"
        case .submit: "submit"
        case .interrupt: "interrupt"
        case .resize: "resize"
        case .clearHistory: "clearHistory"
        case .updateState: "updateState"
        case .kill: "kill"
        case .historyPage: "historyPage"
        case .terminalSnapshot: "terminalSnapshot"
        case .terminalEvent: "terminalEvent"
        case .presence: "presence"
        case .capabilities: "capabilities"
        case .completionRequest: "completionRequest"
        case .completionResponse: "completionResponse"
        case .completionCancel: "completionCancel"
        case .error: "error"
        case .unknown(let value): value
        }
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
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
    public var clientRole: RemoteClientRole?
    public var isHistory: Bool?

    public init(
        version: UInt16 = currentVersion,
        kind: RemoteMessageKind,
        requestID: String,
        macID: String? = nil,
        sessionID: String? = nil,
        sequence: UInt64? = nil,
        payload: Data? = nil,
        clientRole: RemoteClientRole? = nil,
        isHistory: Bool? = nil
    ) {
        self.version = version
        self.kind = kind
        self.requestID = requestID
        self.macID = macID
        self.sessionID = sessionID
        self.sequence = sequence
        self.payload = payload
        self.clientRole = clientRole
        self.isHistory = isHistory
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

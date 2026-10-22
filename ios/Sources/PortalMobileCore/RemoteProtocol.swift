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

    public mutating func recordHeartbeat(_ heartbeat: RemoteMac, sessions: [RemoteCatalogSession]?) {
        var heartbeat = heartbeat
        if let sessions {
            heartbeat.sessions = sessions.filter { $0.commandCount > 0 }
        } else if let previous = macs.first(where: { $0.id == heartbeat.id }) {
            heartbeat.sessions = previous.sessions
        } else {
            return
        }
        macs.removeAll { $0.id == heartbeat.id }
        macs.append(heartbeat)
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
    public static let completion = "ssh-completion-v1"
    public static let history = "ssh-history-v1"
    public static let terminalHistory = "ssh-terminal-history-v1"
    public static let binaryInput = "ssh-binary-input-v1"
    public static let gitStatus = "ssh-git-status-v1"

    public var values: [String]

    public init(values: [String]) {
        self.values = values
    }

    public var supportsBinaryInput: Bool {
        values.contains(Self.binaryInput)
    }

    public var supportsGitStatus: Bool {
        values.contains(Self.gitStatus)
    }
}

public enum RemoteCompletionOperation: String, Codable, CaseIterable, Sendable {
    case completeCommands = "complete-commands"
    case completePath = "complete-path"
    case runGenerator = "run-generator"
    case queryHistory = "history-query"
    case recordHistory = "history-record"
    case clearHistory = "history-clear"
    case gitStatus = "git-status"

    public var requiredCapability: String {
        switch self {
        case .completeCommands, .completePath, .runGenerator:
            RemoteCapabilities.completion
        case .queryHistory, .recordHistory, .clearHistory:
            RemoteCapabilities.history
        case .gitStatus:
            RemoteCapabilities.gitStatus
        }
    }
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
    public var lastCommandAt: Date?
    public var runningCommand: String?
    public var commandHistory: [String]

    public init(
        title: String,
        cwd: String,
        createdAt: Date,
        commandCount: Int,
        lastCommandAt: Date? = nil,
        runningCommand: String?,
        commandHistory: [String]
    ) {
        self.title = title
        self.cwd = cwd
        self.createdAt = createdAt
        self.commandCount = commandCount
        self.lastCommandAt = lastCommandAt
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
    public var lastCommandAt: Date?
    public var runningCommand: String?
    public var attachedClientCount: Int

    public init(sessionID: String, title: String, cwd: String, createdAt: Date, commandCount: Int, lastCommandAt: Date? = nil, runningCommand: String?, attachedClientCount: Int) {
        self.sessionID = sessionID
        self.title = title
        self.cwd = cwd
        self.createdAt = createdAt
        self.commandCount = commandCount
        self.lastCommandAt = lastCommandAt
        self.runningCommand = runningCommand
        self.attachedClientCount = attachedClientCount
    }
}

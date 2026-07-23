import Foundation

struct SSHHostRecord: Codable, Equatable, Sendable {
    var id: String
    var alias: String
    var hostname: String
    var user: String
    var port: Int
    var remoteHelperPath: String
    var enrolled: Bool
}

struct StoredSSHHosts: Codable, Sendable {
    var hosts: [SSHHostRecord]
}

struct RemoteSessionDefaults: Equatable, Sendable {
    var homeDirectory: String
    var shellPath: String
}

enum SessionLocation: Codable, Hashable, Sendable {
    case local
    case sshHost(String)
    case relayMac(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case hostID
        case macID
    }

    private enum Kind: String, Codable {
        case local
        case ssh
        case relay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .local:
            self = .local
        case .ssh:
            self = .sshHost(try container.decode(String.self, forKey: .hostID))
        case .relay:
            self = .relayMac(try container.decode(String.self, forKey: .macID))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local:
            try container.encode(Kind.local, forKey: .kind)
        case .sshHost(let hostID):
            try container.encode(Kind.ssh, forKey: .kind)
            try container.encode(hostID, forKey: .hostID)
        case .relayMac(let macID):
            try container.encode(Kind.relay, forKey: .kind)
            try container.encode(macID, forKey: .macID)
        }
    }
}

struct SessionRef: Codable, Hashable, Sendable {
    var location: SessionLocation
    var sessionID: String

    static func local(_ sessionID: String) -> SessionRef {
        SessionRef(location: .local, sessionID: sessionID)
    }
}

struct SessionMetadata: Decodable, Sendable {
    var sessionID: String
    var title: String
    var cwd: String
    var createdAt: Date
    var commandCount: Int
    var runningCommand: String?
    var commandHistory: [String]
    var attachedClientCount: Int

    init(
        sessionID: String,
        title: String,
        cwd: String,
        createdAt: Date,
        commandCount: Int,
        runningCommand: String?,
        commandHistory: [String],
        attachedClientCount: Int = 0
    ) {
        self.sessionID = sessionID
        self.title = title
        self.cwd = cwd
        self.createdAt = createdAt
        self.commandCount = commandCount
        self.runningCommand = runningCommand
        self.commandHistory = commandHistory
        self.attachedClientCount = attachedClientCount
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case title
        case cwd
        case createdAt
        case commandCount
        case runningCommand
        case commandHistory
        case attachedClientCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        title = try container.decode(String.self, forKey: .title)
        cwd = try container.decode(String.self, forKey: .cwd)
        createdAt = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .createdAt))
        commandCount = try container.decode(Int.self, forKey: .commandCount)
        runningCommand = try container.decodeIfPresent(String.self, forKey: .runningCommand)
        commandHistory = try container.decodeIfPresent([String].self, forKey: .commandHistory) ?? []
        attachedClientCount = try container.decodeIfPresent(Int.self, forKey: .attachedClientCount) ?? 0
    }
}

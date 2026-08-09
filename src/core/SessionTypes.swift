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
    var hostName: String?

    init(location: SessionLocation, sessionID: String, hostName: String? = nil) {
        self.location = location
        self.sessionID = sessionID
        self.hostName = hostName
    }

    static func == (lhs: SessionRef, rhs: SessionRef) -> Bool {
        lhs.location == rhs.location && lhs.sessionID == rhs.sessionID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(location)
        hasher.combine(sessionID)
    }

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
    var lastCommandAt: Date?
    var runningCommand: String?
    var commandHistory: [String]
    var attachedClientCount: Int

    init(
        sessionID: String,
        title: String,
        cwd: String,
        createdAt: Date,
        commandCount: Int,
        lastCommandAt: Date? = nil,
        runningCommand: String?,
        commandHistory: [String],
        attachedClientCount: Int = 0
    ) {
        self.sessionID = sessionID
        self.title = title
        self.cwd = cwd
        self.createdAt = createdAt
        self.commandCount = commandCount
        self.lastCommandAt = lastCommandAt
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
        case lastCommandAt
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
        lastCommandAt = try container.decodeIfPresent(Double.self, forKey: .lastCommandAt)
            .map(Date.init(timeIntervalSince1970:))
        runningCommand = try container.decodeIfPresent(String.self, forKey: .runningCommand)
        commandHistory = try container.decodeIfPresent([String].self, forKey: .commandHistory) ?? []
        attachedClientCount = try container.decodeIfPresent(Int.self, forKey: .attachedClientCount) ?? 0
    }
}

enum SessionDaemonNamespace: Sendable {
    case canonical
    case portalDevelopment
}

struct SessionDaemonIdentity: Sendable {
    // Remove this compatibility routing once the unreleased Portal Terminal namespace drains.
    private static let routingPrefix = "portal-dev-session:v1:"
    private static let canonicalPrefix = routingPrefix + "canonical:"
    private static let portalDevelopmentPrefix = routingPrefix + "portal:"

    var namespace: SessionDaemonNamespace
    var rawSessionID: String

    init(namespace: SessionDaemonNamespace, rawSessionID: String) {
        self.namespace = namespace
        self.rawSessionID = rawSessionID
    }

    init(externalSessionID: String) {
        if let rawSessionID = Self.decode(externalSessionID, prefix: Self.canonicalPrefix) {
            self.init(namespace: .canonical, rawSessionID: rawSessionID)
        } else if let rawSessionID = Self.decode(externalSessionID, prefix: Self.portalDevelopmentPrefix) {
            self.init(namespace: .portalDevelopment, rawSessionID: rawSessionID)
        } else {
            self.init(namespace: .canonical, rawSessionID: externalSessionID)
        }
    }

    var externalSessionID: String {
        switch namespace {
        case .canonical where !rawSessionID.hasPrefix(Self.routingPrefix):
            rawSessionID
        case .canonical:
            Self.canonicalPrefix + Data(rawSessionID.utf8).base64EncodedString()
        case .portalDevelopment:
            Self.portalDevelopmentPrefix + Data(rawSessionID.utf8).base64EncodedString()
        }
    }

    var isPersistable: Bool {
        namespace == .canonical
    }

    private static func decode(_ value: String, prefix: String) -> String? {
        guard value.hasPrefix(prefix),
              let data = Data(base64Encoded: String(value.dropFirst(prefix.count))),
              let decoded = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return decoded
    }
}

enum SessionDaemonInventory {
    static func combine(
        canonical: [SessionMetadata],
        portalDevelopment: [SessionMetadata]
    ) -> [SessionMetadata] {
        canonical.map { metadata in
            var metadata = metadata
            metadata.sessionID = SessionDaemonIdentity(
                namespace: .canonical,
                rawSessionID: metadata.sessionID
            ).externalSessionID
            return metadata
        } + portalDevelopment.map { metadata in
            var metadata = metadata
            metadata.sessionID = SessionDaemonIdentity(
                namespace: .portalDevelopment,
                rawSessionID: metadata.sessionID
            ).externalSessionID
            return metadata
        }
    }
}

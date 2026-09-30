#if os(macOS)
import Foundation
import GitSyncCore

public struct GitHubCounts: Codable, Equatable, Sendable {
    public let stars: Int
    public let issues: Int
    public let pullRequests: Int
    public var summary: String { "\(stars) stars, \(pullRequests) open pull requests, \(issues) open issues" }
}

public struct GitHubNotification: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let repository: String
    public let title: String
    public let body: String
    public let url: URL
    public let alert: Bool
    public var unread: Bool?

    public var safeURL: URL? {
        guard url.scheme == "https", url.host?.lowercased() == "github.com", url.user == nil, url.password == nil else { return nil }
        return url
    }
}

public struct GitHubState: Codable, Equatable, Sendable {
    public var connected = false
    public var status = "Not connected"
    public var pushStatus = "Not registered"
    public var error: String?
    public var notificationPermission = "Not requested"
    public var installationURL: URL?
    public var counts: [String: GitHubCounts] = [:]
    public var notifications: [GitHubNotification] = [] {
        didSet {
            openedNotificationIDs?.formIntersection(notifications.filter { $0.unread == true }.map(\.id))
        }
    }
    public var hasUnreadNotifications: Bool?
    // Optional for older caches. Keep local acknowledgments until the relay confirms read.
    private var openedNotificationIDs: Set<String>?

    public var showsUnreadNotifications: Bool {
        hasUnreadNotifications == true && (openedNotificationIDs?.isEmpty != false || !unreadNotifications.isEmpty)
    }

    public mutating func notificationOpened(id: String) {
        guard notifications.contains(where: { $0.id == id }) else { return }
        openedNotificationIDs = (openedNotificationIDs ?? []).union([id])
    }

    public var unreadNotifications: [GitHubNotification] {
        var threads = Set<Substring>()
        // The relay orders newest first; IDs are "threadID:updated_at".
        return notifications.filter {
            $0.unread == true && threads.insert($0.id.prefix { $0 != ":" }).inserted
                && openedNotificationIDs?.contains($0.id) != true
        }
    }
    public init() {}
}

public enum GitHubAction: Codable, Sendable {
    case connect, refresh, disconnect, requestNotificationPermission, installations
    case notificationOpened(id: String)
}

struct GitHubWork: Codable, Sendable {
    let id: UUID
    let repository: String
    let kind: String
}

struct GitHubResponse: Decodable, Sendable {
    let counts: [String: GitHubCounts]
    let notifications: [GitHubNotification]
    let hasUnreadNotifications: Bool?
    let authorizedRepositories: [String]
    let fetches: [GitHubWork]
    let merges: [MergedBranch]?
    let retryAfter: Double?
    let errors: [String]
    let installationURL: URL
}

/// An idle controller has no timer. Only an external trigger can start a bounded batch.
struct GitHubRefreshSchedule {
    private(set) var requested = false
    private(set) var catchUp = false
    private(set) var retries = 0
    mutating func request(catchUp: Bool) {
        requested = true
        self.catchUp = self.catchUp || catchUp
        retries = 0
    }
    mutating func take() -> Bool? {
        guard requested else { return nil }
        let value = catchUp
        requested = false
        catchUp = false
        return value
    }
    mutating func preserveCatchUp() { catchUp = true }
    mutating func retry() -> Bool {
        guard retries < 3 else { return false }
        retries += 1
        requested = true
        return true
    }
}
#endif

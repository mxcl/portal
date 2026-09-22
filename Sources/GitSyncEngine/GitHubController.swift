#if os(macOS)
import AppKit
import Combine
import Foundation
import GitSyncCore
import Network
import Security
import UserNotifications

@MainActor
public final class GitHubController: NSObject, UNUserNotificationCenterDelegate {
    private weak var model: EngineModel?
    private let cacheURL: URL
    private var credential: Credential?
    private var deviceToken: String?
    private var task: Task<Void, Never>?
    private var schedule = GitHubRefreshSchedule()
    private var observations = Set<AnyCancellable>()
    private let network = NWPathMonitor()
    private var online = false
    private var ready = false
    private var accountActionInProgress = false
    private var seen = Set<String>()
    private let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)

    private struct Credential: Codable { let relay: URL; let session: UUID }
    private struct Cache: Codable { let state: GitHubState; let seen: Set<String> }
    private struct ConnectResponse: Decodable { let session: UUID; let url: URL }
    private struct SyncRequest: Encodable {
        let repositories: [String]
        let catchUp: Bool
        let token: String?
        let environment: String
    }
    private struct RequestError: LocalizedError {
        let message: String
        let retryAfter: Double?
        var errorDescription: String? { message }
    }

    public init(model: EngineModel) {
        self.model = model
        cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitSync/github.json")
        super.init()
        do {
            if let data = try Self.readCredential() { credential = try JSONDecoder().decode(Credential.self, from: data) }
            if credential != nil, let data = try? Data(contentsOf: cacheURL),
               let cache = try? JSONDecoder().decode(Cache.self, from: data) {
                model.github = cache.state
                seen = cache.seen
            }
        } catch { model.github.error = error.localizedDescription }
        if let credential {
            model.github.relayURL = credential.relay.absoluteString
            model.github.connected = true
        }
        model.githubAction = { [weak self] action in await self?.handle(action) }
        UNUserNotificationCenter.current().delegate = self
        model.$localProjects.combineLatest(model.$remoteProjects)
            .map { local, peers in Set((Array(local.values) + peers.values.flatMap { $0.values })
                .filter { $0.placement != .notPresent }.flatMap { $0.githubRepositories ?? [] }) }
            .removeDuplicates().dropFirst().sink { [weak self] _ in self?.refresh(catchUp: false) }
            .store(in: &observations)
        model.$isPaused.removeDuplicates().dropFirst().filter { !$0 }
            .sink { [weak self] _ in self?.refresh(catchUp: false) }.store(in: &observations)
        network.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if satisfied && !self.online { self.refresh(catchUp: true) }
                self.online = satisfied
            }
        }
        network.start(queue: DispatchQueue(label: "gitinuum.github-network"))
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh(catchUp: true) }.store(in: &observations)
        Task { [weak self] in
            await model.refreshProjectStatuses()
            await self?.updatePermission()
            self?.ready = true
            self?.refresh(catchUp: true)
        }
    }

    public func shutdown() { task?.cancel(); network.cancel() }
    public func registered(token: Data) {
        model?.github.pushStatus = "Registered"
        deviceToken = token.map { String(format: "%02x", $0) }.joined()
        refresh(catchUp: false)
    }
    public func registrationFailed(_ error: Error) { model?.github.pushStatus = error.localizedDescription }
    public func receivedPush() { refresh(catchUp: false) }

    private var repositories: Set<String> {
        guard let model else { return [] }
        return Set((Array(model.localProjects.values) + model.remoteProjects.values.flatMap { $0.values })
            .filter { $0.placement != .notPresent }.flatMap { $0.githubRepositories ?? [] })
    }

    public func handle(_ action: GitHubAction) async {
        guard let model else { return }
        guard !accountActionInProgress else { return }
        switch action {
        case .connect, .disconnect: accountActionInProgress = true
        default: break
        }
        defer { accountActionInProgress = false }
        do {
            switch action {
            case .connect(let address):
                guard credential == nil else { throw RequestError(message: "Disconnect before connecting another account.", retryAfter: nil) }
                guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
                      url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
                      url.query == nil, url.fragment == nil else {
                    throw RequestError(message: "Enter an HTTPS relay URL.", retryAfter: nil)
                }
                let data = try await request("connect", body: Data("{}".utf8), relay: url, credential: nil)
                let reply = try JSONDecoder().decode(ConnectResponse.self, from: data)
                guard reply.url.scheme == "https", reply.url.host == "github.com", reply.url.path == "/login/oauth/authorize" else {
                    throw RequestError(message: "Relay returned an invalid sign-in URL.", retryAfter: nil)
                }
                let value = Credential(relay: url, session: reply.session)
                try Self.saveCredential(JSONEncoder().encode(value))
                credential = value
                model.github.relayURL = url.absoluteString
                model.github.status = "Finish connecting in your browser, then Refresh."
                model.github.connected = true // A session exists; status distinguishes authorization from readiness.
                model.github.error = nil
                NSWorkspace.shared.open(reply.url)
            case .refresh:
                await updatePermission()
                await model.refreshProjectStatuses()
                refresh(catchUp: true)
            case .disconnect:
                task?.cancel()
                if let credential {
                    _ = try await request("disconnect", body: Data("{}".utf8), relay: credential.relay, credential: credential.session)
                }
                try Self.deleteCredential()
                credential = nil
                seen = []
                model.github = GitHubState()
                try? FileManager.default.removeItem(at: cacheURL)
            case .requestNotificationPermission:
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                NSApplication.shared.registerForRemoteNotifications()
                await updatePermission()
            case .installations:
                if let url = model.github.installationURL, url.scheme == "https", url.host == "github.com" { NSWorkspace.shared.open(url) }
            }
        } catch { model.github.error = error.localizedDescription }
    }

    private func refresh(catchUp: Bool) {
        guard ready, credential != nil else { return }
        schedule.request(catchUp: catchUp)
        guard task == nil else { return }
        task = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        defer { task = nil }
        while !Task.isCancelled, let catchUp = schedule.take(), let credential, let model {
            var delay: Double?
            do {
                let input = SyncRequest(repositories: repositories.sorted(), catchUp: catchUp,
                                        token: deviceToken, environment: Self.apnsEnvironment)
                let data = try await request("sync", body: JSONEncoder().encode(input), relay: credential.relay, credential: credential.session)
                try Task.checkCancellation()
                let response = try JSONDecoder().decode(GitHubResponse.self, from: data)
                let authorized = Set(response.authorizedRepositories).intersection(repositories)
                model.github.connected = true
                model.github.status = "Connected"
                model.github.installationURL = response.installationURL
                model.github.counts = model.github.counts.filter { authorized.contains($0.key) }
                    .merging(response.counts.filter { authorized.contains($0.key) }) { _, new in new }
                model.github.notifications = response.notifications.filter { authorized.contains($0.repository) }
                let missing = repositories.subtracting(authorized)
                model.github.error = (response.errors + (missing.isEmpty ? [] : ["Unavailable repositories: \(missing.sorted().joined(separator: ", ")). Check remote URLs and Repository Access."]))
                    .first
                for note in model.github.notifications where !seen.contains(note.id) {
                    if note.alert, model.github.notificationPermission == "Allowed" {
                        do { try await present(note) }
                        catch {
                            await updatePermission()
                            model.github.error = "Could not show banner: \(error.localizedDescription)"
                        }
                    }
                    seen.insert(note.id)
                }
                // The relay history is capped; retain only IDs that can be returned again in its current window.
                seen.formIntersection(Set(model.github.notifications.map(\.id)))
                saveCache()
                delay = response.retryAfter
                var completed: [UUID] = []
                for work in response.fetches where authorized.contains(work.repository) {
                    guard !model.isPaused else { break }
                    let root = URL(fileURLWithPath: NSString(string: model.configuration.root).expandingTildeInPath)
                    let peers = model.configuration.hosts.map(\.machine) + [model.configuration.machine]
                    do {
                        let candidates = try await Task.detached(priority: .utility) {
                            try Repository.discover(in: root).filter { $0.placement == .checkedOut && $0.githubRepositories.contains(work.repository) }
                        }.value
                        var finished = true
                        for repository in candidates {
                            try Task.checkCancellation()
                            if model.isPaused { finished = false; break }
                            try await Task.detached(priority: .utility) {
                                try repository.fetchGitHub(work.repository, peerMachines: peers)
                            }.value
                        }
                        if finished { completed.append(work.id) }
                    } catch {
                        try Task.checkCancellation()
                        model.github.error = "GitHub fetch: \(error.localizedDescription)"
                        delay = max(delay ?? 0, 30)
                    }
                }
                try Task.checkCancellation()
                if !completed.isEmpty {
                    _ = try await request("ack", body: JSONEncoder().encode(completed), relay: credential.relay, credential: credential.session)
                }
            } catch {
                if Task.isCancelled { return }
                model.github.error = error.localizedDescription
                delay = (error as? RequestError)?.retryAfter ?? 30
                // An unsuccessful catch-up still needs to enqueue its work on the next attempt.
                if catchUp { schedule.preserveCatchUp() }
            }
            guard !Task.isCancelled else { return }
            if let delay, schedule.retry() {
                do { try await Task.sleep(for: .seconds(max(1, delay))) } catch { return }
            }
        }
    }

    private func present(_ note: GitHubNotification) async throws {
        guard let url = note.safeURL else { return }
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        content.sound = .default
        content.userInfo = ["url": url.absoluteString]
        content.threadIdentifier = note.repository
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: note.id, content: content, trigger: nil))
    }
    private func updatePermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        model?.github.notificationPermission = switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: "Allowed"
        case .denied: "Disabled in System Settings"
        default: "Not requested"
        }
    }
    private func saveCache() {
        guard let model else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Cache(state: model.github, seen: seen)).write(to: cacheURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        } catch { model.github.error = "Could not save GitHub cache: \(error.localizedDescription)" }
    }
    private func request(_ path: String, body: Data, relay: URL, credential: UUID?) async throws -> Data {
        var request = URLRequest(url: relay.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Gitinuum-Protocol")
        if let credential { request.setValue("Bearer \(credential.uuidString)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String
            throw RequestError(message: reason ?? "Relay returned HTTP \(http.statusCode)",
                               retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        }
        return data
    }
    private static var apnsEnvironment: String {
        // Packaging records the environment from the signed provisioning profile.
        Bundle.main.object(forInfoDictionaryKey: "GitinuumAPNSEnvironment") as? String ?? "production"
    }
    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.mxcl.git-sync.github",
         kSecAttrAccount as String: "relay-session"]
    }
    private static func readCredential() throws -> Data? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return value as? Data
    }
    private static func saveCredential(_ data: Data) throws {
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(keychainQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var query = keychainQuery.merging(update) { _, new in new }
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    private static func deleteCredential() throws {
        let status = SecItemDelete(keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let text = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: text), url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil {
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }
}
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
#endif

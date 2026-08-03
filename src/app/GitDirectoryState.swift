import Darwin
import Foundation

final class GitDirectoryStateProvider {
    struct Summary {
        let branch: String
        let isDirty: Bool
        let insertions: Int
        let deletions: Int
    }

    private struct CacheEntry {
        let expiresAt: Date
        let summary: Summary?
    }

    private struct RepositoryLocation {
        let worktreePath: String
        let gitDirectoryPath: String
    }

    private struct RemoteGitStatusRequest: Encodable {
        let cwd: String
    }

    private struct RemoteGitStatusResponse: Decodable {
        let summary: RemoteGitSummary?
    }

    private struct RemoteGitSummary: Decodable {
        let worktreePath: String
        let branch: String
        let isDirty: Bool
        let insertions: Int
        let deletions: Int
    }

    private let fileManager = FileManager.default
    private let lock = NSLock()
    private let cacheTTL: TimeInterval
    private var cache: [String: CacheEntry] = [:]

    init(cacheTTL: TimeInterval = 2) {
        self.cacheTTL = cacheTTL
    }

    func repositoryRoot(forDirectory url: URL) -> String? {
        let path = url.standardizedFileURL.path
        return repositoryLocation(containing: path)?.worktreePath
    }

    func summary(
        forDirectory url: URL,
        location: SessionLocation,
        forceRefresh: Bool = false
    ) -> Summary? {
        switch location {
        case .local:
            return summary(forDirectory: url, forceRefresh: forceRefresh)
        case .sshHost(let hostID):
            return remoteSummary(forDirectory: url, hostID: hostID, forceRefresh: forceRefresh)
        case .relayMac:
            // ponytail: relay Git status waits for a typed query message.
            return nil
        }
    }

    func summary(forDirectory url: URL, forceRefresh: Bool = false) -> Summary? {
        let path = url.standardizedFileURL.path
        guard let location = repositoryLocation(containing: path) else { return nil }

        let now = Date()
        if !forceRefresh {
            lock.lock()
            if let entry = cache[location.worktreePath], entry.expiresAt > now {
                lock.unlock()
                return entry.summary
            }
            lock.unlock()
        }

        let summary = loadSummary(for: location)
        lock.lock()
        cache[location.worktreePath] = CacheEntry(
            expiresAt: now.addingTimeInterval(cacheTTL),
            summary: summary
        )
        lock.unlock()
        return summary
    }

    private func remoteSummary(forDirectory url: URL, hostID: String, forceRefresh: Bool) -> Summary? {
        let path = url.standardizedFileURL.path
        let now = Date()
        let key = remoteCacheKey(hostID: hostID, path: path)
        if !forceRefresh {
            lock.lock()
            if let entry = cache[key], entry.expiresAt > now {
                lock.unlock()
                return entry.summary
            }
            lock.unlock()
        }

        let remote = loadRemoteSummary(hostID: hostID, cwd: path)
        let summary = remote.map {
            Summary(
                branch: $0.branch,
                isDirty: $0.isDirty,
                insertions: $0.insertions,
                deletions: $0.deletions
            )
        }
        let entry = CacheEntry(expiresAt: now.addingTimeInterval(cacheTTL), summary: summary)
        lock.lock()
        cache[key] = entry
        if let worktreePath = remote?.worktreePath {
            cache[remoteCacheKey(hostID: hostID, path: worktreePath)] = entry
        }
        lock.unlock()
        return summary
    }

    private func loadRemoteSummary(hostID: String, cwd: String) -> RemoteGitSummary? {
        do {
            let input = try JSONEncoder().encode(RemoteGitStatusRequest(cwd: cwd))
            let output = try PtySession.runSSHBridgeSubcommand(
                hostID: hostID,
                arguments: ["git-status"],
                input: input,
                timeout: 2
            )
            return try JSONDecoder().decode(RemoteGitStatusResponse.self, from: output).summary
        } catch {
            return nil
        }
    }

    private func remoteCacheKey(hostID: String, path: String) -> String {
        "ssh:\(hostID):\(path)"
    }

    private func repositoryLocation(containing path: String) -> RepositoryLocation? {
        var cursor = (path as NSString).standardizingPath
        while true {
            let gitPath = (cursor as NSString).appendingPathComponent(".git")
            if directoryExists(at: gitPath) {
                return RepositoryLocation(worktreePath: cursor, gitDirectoryPath: gitPath)
            }
            if fileManager.fileExists(atPath: gitPath),
               let redirectedGitPath = redirectedGitDirectory(from: gitPath, relativeTo: cursor) {
                return RepositoryLocation(worktreePath: cursor, gitDirectoryPath: redirectedGitPath)
            }

            let parent = (cursor as NSString).deletingLastPathComponent
            if parent == cursor || parent.isEmpty {
                return nil
            }
            cursor = parent
        }
    }

    private func redirectedGitDirectory(from gitFilePath: String, relativeTo worktreePath: String) -> String? {
        guard let contents = try? String(contentsOfFile: gitFilePath, encoding: .utf8) else {
            return nil
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("gitdir:") else { return nil }

        let rawPath = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        if rawPath.hasPrefix("/") {
            return (rawPath as NSString).standardizingPath
        }
        return ((worktreePath as NSString).appendingPathComponent(rawPath) as NSString).standardizingPath
    }

    private func loadSummary(for location: RepositoryLocation) -> Summary? {
        guard let output = gitStatusOutput(in: location.worktreePath) else {
            guard let branch = branchName(in: location.gitDirectoryPath) else {
                return nil
            }
            return Summary(branch: branch, isDirty: false, insertions: 0, deletions: 0)
        }

        let status = parseGitStatus(output)
        guard let branch = status.branch else { return nil }
        let lineChanges = status.isDirty
            ? gitDiffLineChanges(in: location.worktreePath)
            : LineChanges()

        return Summary(
            branch: branch,
            isDirty: status.isDirty,
            insertions: lineChanges.insertions,
            deletions: lineChanges.deletions
        )
    }

    private func gitStatusOutput(in worktreePath: String) -> String? {
        gitOutput(
            in: worktreePath,
            arguments: [
                "--no-optional-locks",
                "status",
                "--porcelain=v1",
                "--branch",
                "--untracked-files=normal"
            ]
        )
    }

    private func gitDiffLineChanges(in worktreePath: String) -> LineChanges {
        guard let output = gitOutput(
            in: worktreePath,
            arguments: [
                "--no-optional-locks",
                "diff",
                "--numstat",
                "HEAD",
                "--"
            ]
        ) else {
            return LineChanges()
        }
        return parseNumstat(output)
    }

    private func gitOutput(in worktreePath: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", worktreePath] + arguments

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        return String(data: data, encoding: .utf8)
    }

    private func parseGitStatus(_ output: String) -> (branch: String?, isDirty: Bool) {
        var branch: String?
        var isDirty = false

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                branch = branchName(fromStatusBranchLine: String(line))
                continue
            }

            guard line.count >= 2 else { continue }
            let indexStatus = line[line.startIndex]
            let worktreeStatus = line[line.index(after: line.startIndex)]
            isDirty = isDirty || indexStatus != " " || worktreeStatus != " "
        }

        return (branch, isDirty)
    }

    private struct LineChanges {
        var insertions = 0
        var deletions = 0
    }

    private func parseNumstat(_ output: String) -> LineChanges {
        var lineChanges = LineChanges()

        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            if let insertions = Int(fields[0]) {
                lineChanges.insertions += insertions
            }
            if let deletions = Int(fields[1]) {
                lineChanges.deletions += deletions
            }
        }

        return lineChanges
    }

    private func branchName(fromStatusBranchLine line: String) -> String? {
        guard line.hasPrefix("## ") else { return nil }
        var value = String(line.dropFirst(3))
        if let bracketRange = value.range(of: " [") {
            value.removeSubrange(bracketRange.lowerBound..<value.endIndex)
        }
        if let upstreamRange = value.range(of: "...") {
            value.removeSubrange(upstreamRange.lowerBound..<value.endIndex)
        }
        if value.hasPrefix("Initial commit on ") {
            value = String(value.dropFirst("Initial commit on ".count))
        }
        if value == "HEAD (no branch)" {
            return "HEAD"
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func branchName(in gitDirectoryPath: String) -> String? {
        let headPath = (gitDirectoryPath as NSString).appendingPathComponent("HEAD")
        guard let contents = try? String(contentsOfFile: headPath, encoding: .utf8) else {
            return nil
        }

        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref:") {
            let refName = trimmed.dropFirst("ref:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if refName.hasPrefix("refs/heads/") {
                return String(refName.dropFirst("refs/heads/".count))
            }
            return String(refName)
        }
        return String(trimmed.prefix(7))
    }

    private func directoryExists(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

#if os(macOS)
import Foundation
import Testing
@testable import GitSyncApp
@testable import GitSyncEngine
@testable import GitSyncCore

@Test("Sidebar counts use the local GitHub identity or the first known peer without inventing zero counts")
@MainActor
func githubSidebarCounts() throws {
    let model = AppModel(connectToHelper: false)
    let host = SyncHost(machine: "peer", peer: "peer", root: "/tmp/projects")
    model.configuration.hosts = [host]
    model.remoteProjects = [host.id: ["remote": PeerProject(name: "remote", placement: .checkedOut,
        githubRepositories: ["owner/remote"])]]
    model.localProjects = ["local": PeerProject(name: "local", placement: .checkedOut,
        githubRepositories: ["owner/local", "owner/remote"])]
    model.github.counts = ["owner/local": GitHubCounts(stars: 10, issues: 3, pullRequests: 2),
                           "owner/remote": GitHubCounts(stars: 4, issues: 1, pullRequests: 0)]
    #expect(model.githubCounts(for: "local")?.stars == 10)
    #expect(model.githubCounts(for: "remote")?.stars == 4)
    #expect(model.githubCounts(for: "unknown") == nil)
    #expect(model.githubCounts(for: "remote")?.summary == "4 stars, 0 open pull requests, 1 open issues")
}
@Test("Sidebar sums dirty hosts, omits clean trees, and retains binary-only indicators")
@MainActor
func workingTreeSidebarCounts() throws {
    let model = AppModel(connectToHelper: false)
    let host = SyncHost(machine: "peer", peer: "peer", root: "/tmp/projects")
    model.configuration.hosts = [host]
    func project(_ porcelain: String, _ numstat: String = "") throws -> PeerProject {
        var changes = RepositoryWorkingChanges(porcelain: Data(porcelain.utf8))
        changes.addLineCounts(Data(numstat.utf8))
        let project = PeerProject(name: "project", placement: .checkedOut, workingChanges: changes)
        return try JSONDecoder().decode(PeerProject.self, from: JSONEncoder().encode(project))
    }
    model.localProjects = ["project": try project("MM file\0", "3\t2\tfile\0")]
    model.remoteProjects = [host.id: ["project": try project("?? new\0", "5\t0\tnew\0")]]
    #expect(model.workingChangeCounts(for: "project")?.additions == 8)
    #expect(model.workingChangeCounts(for: "project")?.deletions == 2)
    model.localProjects["project"] = try project("")
    #expect(model.workingChangeCounts(for: "project")?.additions == 5)
    model.remoteProjects[host.id]?["project"] = try project(" M binary\0")
    #expect(model.workingChangeCounts(for: "project")?.additions == 0)
    #expect(model.workingChangeCounts(for: "project")?.deletions == 0)
    model.remoteProjects[host.id]?["project"] = try project("")
    #expect(model.workingChangeCounts(for: "project") == nil)
    #expect(model.workingChangeCounts(for: "unknown") == nil)
    model.configuration.hosts = []
    model.remoteProjects[host.id]?["project"] = try project(" M file\0", "9\t9\tfile\0")
    #expect(model.workingChangeCounts(for: "project") == nil)
}
@Test("Sidebar branch dot compares only the default branch on checked-out hosts and this Mac’s GitHub refs")
@MainActor
func branchDifferenceSidebar() throws {
    let model = AppModel(connectToHelper: false)
    let host = SyncHost(machine: "peer", peer: "peer", root: "/tmp/projects")
    model.configuration.hosts = [host]
    func project(_ local: [String: String], github: [String: String] = [:],
                 placement: ProjectPlacement = .checkedOut, defaultBranch: String? = "main") throws -> PeerProject {
        let value = PeerProject(name: "project", placement: placement, defaultBranch: defaultBranch,
                                branchTips: RepositoryBranchTips(local: local, github: github))
        return try JSONDecoder().decode(PeerProject.self, from: JSONEncoder().encode(value))
    }
    model.localProjects["project"] = try project(["main": "a"])
    model.remoteProjects[host.id] = ["project": try project(["main": "a", "topic": "b"])]
    #expect(!model.hasBranchDifferences(for: "project"))
    model.remoteProjects[host.id]?["project"] = try project(["main": "b"])
    #expect(model.hasBranchDifferences(for: "project"))
    model.remoteProjects[host.id]?["project"] = try project(["main": "b"], placement: .mirrored)
    #expect(!model.hasBranchDifferences(for: "project"))
    // A peer's stale GitHub cache must not light the dot on this Mac.
    model.localProjects["project"] = try project(["main": "a"], github: ["main": "a"])
    model.remoteProjects[host.id]?["project"] = try project(["main": "a"], github: ["main": "b"])
    #expect(!model.hasBranchDifferences(for: "project"))
    model.localProjects = [:]
    #expect(!model.hasBranchDifferences(for: "project"))
    model.configuration.hosts = []
    #expect(!model.hasBranchDifferences(for: "project"))
    model.localProjects["project"] = try project(["main": "a"], github: ["main": "a"])
    #expect(!model.hasBranchDifferences(for: "project"))
    model.localProjects["project"] = try project(["main": "a"], github: ["main": "b"])
    #expect(model.hasBranchDifferences(for: "project"))
    model.localProjects["project"] = try project(["main": "a", "topic": "b"],
        github: ["main": "a", "topic": "c"])
    model.configuration.hosts = [host]
    model.remoteProjects[host.id]?["project"] = try project(["main": "a", "topic": "d"])
    #expect(!model.hasBranchDifferences(for: "project"))
    model.localProjects["project"] = try project(["trunk": "a"], defaultBranch: "trunk")
    model.remoteProjects[host.id]?["project"] = try project(["trunk": "b"], defaultBranch: "trunk")
    #expect(model.hasBranchDifferences(for: "project"))
    model.localProjects = [:]
    model.remoteProjects[host.id]?["project"] = try project(["trunk": "a"], github: ["trunk": "b"], defaultBranch: "trunk")
    #expect(!model.hasBranchDifferences(for: "project"))
    model.remoteProjects[host.id]?["project"] = try project(["main": "a"], github: ["main": "b"], defaultBranch: nil)
    #expect(!model.hasBranchDifferences(for: "project"))
    #expect(!model.hasBranchDifferences(for: "unknown"))
}
#endif

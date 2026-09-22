#if os(macOS)
import Foundation
import Testing
@testable import GitSyncApp
@testable import GitSyncEngine
import GitSyncCore

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
#endif

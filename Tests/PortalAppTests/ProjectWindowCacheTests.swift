import Foundation
import Testing
@testable import PortalApp
@testable import PortalEngine
import PortalCore

@Test("opening the window restores content before any asynchronous Git read")
@MainActor
func restoresProjectWindowImmediately() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = directory.appendingPathComponent("project")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["init", "--quiet", "--initial-branch=fresh", repository.path]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let configuration = AppConfiguration(root: directory.path, machine: "test",
                                         folders: [SyncFolder(name: "project", availableLocally: true)])
    let engine = EngineModel(executableURL: URL(fileURLWithPath: "/usr/bin/false"),
                             configuration: configuration, support: directory)
    let content = RepositoryContent(snapshot: RepositorySnapshot(commits: [], references: [], head: "main", branches: ["main"]),
                                    readme: RepositoryReadme(markdown: "Cached README", source: "README.md"), githubURL: nil)
    let url = directory.appendingPathComponent("window.json")
    let cache = ProjectWindowCache(engine: engine.snapshot(), name: "project", source: .local,
                                   showAuxiliaryHistory: UserDefaults.standard.bool(forKey: "show-detached-worktrees"), content: content)
    try JSONEncoder().encode(cache).write(to: url)
    let model = AppModel(connectToHelper: false, windowCacheURL: url)
    #expect(model.selectedProjectName == "project")
    #expect(model.projectSnapshot == content.snapshot)
    #expect(model.projectReadme == content.readme)
    #expect(!model.helperAvailable)
    let deadline = Date().addingTimeInterval(5)
    while model.isLoadingProject && Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.projectError == nil)
    #expect(model.projectSnapshot?.head == "fresh")
    #expect(model.projectReadme == nil)
    while Date() < deadline {
        let saved = try JSONDecoder().decode(ProjectWindowCache.self, from: Data(contentsOf: url))
        if saved.content.snapshot.head == "fresh" { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let reopened = AppModel(connectToHelper: false, windowCacheURL: url)
    #expect(reopened.projectSnapshot?.head == "fresh")
    let incompatible = ProjectWindowCache(engine: cache.engine, name: cache.name, source: cache.source,
                                           showAuxiliaryHistory: !cache.showAuxiliaryHistory, content: cache.content)
    try JSONEncoder().encode(incompatible).write(to: url)
    let changedPreference = AppModel(connectToHelper: false, windowCacheURL: url)
    #expect(changedPreference.projectSnapshot == nil)
    try Data("invalid cache".utf8).write(to: url)
    let uncached = AppModel(connectToHelper: false, windowCacheURL: url)
    #expect(uncached.projectSnapshot == nil)
}

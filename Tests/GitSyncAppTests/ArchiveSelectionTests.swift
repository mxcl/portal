import Foundation
import Testing
@testable import GitSyncApp
@testable import GitSyncCore
@testable import GitSyncEngine

@Test("archiving keeps the selected project, commit, and content while switching to its backup")
@MainActor
func archivePreservesSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = root.appendingPathComponent("source")
    let backup = root.appendingPathComponent("backup")
    let support = root.appendingPathComponent("support")
    for directory in [source, backup, support] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: root) }
    let savedSelection = UserDefaults.standard.object(forKey: "selected-project-v2")
    defer { UserDefaults.standard.set(savedSelection, forKey: "selected-project-v2") }
    let project = source.appendingPathComponent("project")
    _ = try Git.run(["init", "-q", "-b", "main", project.path])
    try Data("# Project\n".utf8).write(to: project.appendingPathComponent("README.md"))
    _ = try Git.run(["-C", project.path, "add", "."])
    _ = try Git.run(["-C", project.path, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                     "commit", "-q", "-m", "Initial commit"])
    let oid = try Git.text(["-C", project.path, "rev-parse", "HEAD"])
    try OneShot.sync(sourceRoot: source, destinationRoot: backup, machine: "test",
                     stateURL: root.appendingPathComponent("state.json"), bareDestination: true)
    let destination = BackupDestinationConfiguration(root: backup.path)
    let model = AppModel(connectToHelper: false)
    #expect(model.backupStatus(for: "project").title == "Backup not configured")
    model.configuration = AppConfiguration(root: source.path, machine: "test",
        folders: [SyncFolder(name: "project", isLocal: true, availableLocally: true)],
        backupDestination: destination)
    #expect(model.backupStatus(for: "project").title == "No backup found")
    #expect(model.openProjectURL(URL(string: "gitsync://project?name=project")!))
    #expect(model.selectedProjectName == "project")
    #expect(!model.openProjectURL(URL(string: "gitsync://project?name=..%2Foutside")!))
    #expect(model.selectedProjectName == "project")
    var deadline = Date().addingTimeInterval(5)
    while model.isLoadingProject && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    model.selectCommit(oid)
    deadline = Date().addingTimeInterval(5)
    while model.isLoadingCommitDiff && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let diff = try #require(model.selectedCommitDiff)
    // A List may send the same selection again when the row changes sections.
    model.selectProject("project")
    #expect(model.selectedCommitID == oid)

    let engine = EngineModel(executableURL: URL(fileURLWithPath: "/usr/bin/false"),
        configuration: AppConfiguration(root: source.path, machine: "test",
            folders: [SyncFolder(name: "project")], backupDestination: destination), support: support)
    let indexURL = support.appendingPathComponent("backup-index-\(destination.id.uuidString).json")
    try BackupIndex(url: indexURL).replaceCatalog(machine: "test", repositories: [])
    try engine.loadBackupIndex()
    deadline = Date().addingTimeInterval(5)
    while engine.backupItems.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(engine.backupItems.first?.status == .archived)
    model.apply(engine.snapshot())
    #expect(model.backupStatus(for: "project").title == "Backup available")
    #expect(model.backupStatus(for: "project").detail.contains("test"))
    #expect(model.backupStatus(for: "another-project").title == "No backup found")
    model.backupError = "Backup host offline"
    #expect(model.backupStatus(for: "project").title == "Backup status unavailable")
    #expect(model.backupStatus(for: "project").detail == "Backup host offline")
    model.backupError = nil
    model.helperError = "Helper unavailable"
    #expect(model.backupStatus(for: "project").title == "Backup status unavailable")
    model.helperError = nil
    #expect(model.selectedProjectName == "project")
    #expect(model.selectedCommitID == oid)
    #expect(model.projectReadme?.markdown == "# Project\n")
    #expect(model.selectedCommitDiff == diff)
    #expect(model.projectSnapshot?.commits.contains(where: { $0.oid == oid }) == true)
    #expect(model.projectNames.isEmpty)
    #expect(model.archivedProjects.map(\.name) == ["project"])
    #expect(model.isSelectedProjectArchived)
    #expect(model.toolbarTabs == [.info, .diff])
    deadline = Date().addingTimeInterval(5)
    while model.isLoadingProject && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.projectError == nil)
    #expect(model.selectedCommitID == oid)
    #expect(model.selectedCommitDiff == diff)
    #expect(model.projectReadme?.markdown == "# Project\n")
    #expect(model.openProjectURL(URL(string: "gitsync://project?name=space%20%26%20unicode%20%C3%A9")!))
    #expect(model.selectedProjectName == "space & unicode é")
}

#if os(macOS)
import Foundation
import AppKit
import CodeEditLanguages
import Testing
@testable import GitSyncApp
@testable import GitSyncCore

@Test("Bundled Swift syntax queries load successfully")
@MainActor
func editorSyntaxResources() throws {
    let url = try #require(CodeLanguage.swift.queryURL)
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(TreeSitterModel.shared.query(for: .swift) != nil)
}

@Test("CodeEdit receives a component color for its minimap brightness calculation")
@MainActor
func editorBackgroundColor() {
    let background = ProjectEditorView(editor: ProjectEditor()).theme.background
    #expect(background.type == .componentBased)
    #expect((0...1).contains(background.brightnessComponent))
}

@Test("File outline preserves full paths, groups directories first, and keeps unusual filenames")
func editorFileTree() {
    let tree = FileNode.tree(["z.txt", "Sources/b.swift", "Sources/Nested/a.swift", "a\nb.txt"])
    #expect(tree.map(\.id) == ["Sources", "a\nb.txt", "z.txt"])
    #expect(tree[0].children?.map(\.id) == ["Sources/Nested", "Sources/b.swift"])
    #expect(tree[0].children?.first?.children?.first?.id == "Sources/Nested/a.swift")
    #expect(tree[1].children == nil)
}

@Test("Editor retains drafts across refresh and keeps them after a save conflict")
@MainActor
func editorDraftLifecycle() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    _ = try Git.run(["init", "-q", root.path])
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("a.txt")
    try Data("original\n".utf8).write(to: url)
    let editor = ProjectEditor()
    editor.connect(root)
    editor.open("a.txt")
    let deadline = Date().addingTimeInterval(5)
    while !editor.canEdit && editor.error == nil && Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(editor.canEdit)
    #expect(!editor.isDirty)
    editor.text = "draft\n"
    editor.connect(root)
    editor.refresh()
    #expect(editor.isDirty)
    #expect(editor.text == "draft\n")
    #expect(editor.save())
    #expect(!editor.isDirty)
    #expect(try String(contentsOf: url, encoding: .utf8) == "draft\n")
    editor.text = "another draft\n"
    try Data("outside\n".utf8).write(to: url)
    #expect(!editor.save())
    #expect(editor.isDirty)
    #expect(editor.text == "another draft\n")
    #expect(editor.error != nil)
    editor.discard()
    #expect(!editor.isDirty)
    #expect(editor.text == "draft\n")
    #expect(try String(contentsOf: url, encoding: .utf8) == "outside\n")
}
#endif

#if os(macOS)
import Foundation
import AppKit
import CodeEditLanguages
import CodeEditTextView
@testable import CodeEditSourceEditor
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

@Test("Markdown highlights block and inline syntax, including fenced code")
@MainActor
func editorMarkdownHighlighting() throws {
    let source = """
    # Heading 🦄 with `code`

    Setext heading
    ==============

    Plain **bold** and *italic*, [link](https://example.com).

    - List item
    > Quote

    ```swift
    let value = "hello"
    ```

    ```js
    const value = 42;
    ```
    """
    let textView = TextView(string: source)
    let client = TreeSitterClient()
    client.readCallback = textView.createReadCallback()
    client.state = TreeSitterState(codeLanguage: .markdown,
                                   readCallback: textView.createReadCallback(),
                                   readBlock: textView.createReadBlock())
    let range = NSRange(location: 0, length: (source as NSString).length)
    let highlights = client.queryHighlightsForRange(range: range).sorted { $0.range.location < $1.range.location }
    // Exercise the same overlap resolution as the visible editor.
    let container = StyledRangeContainer(documentLength: range.length, providers: [0])
    container.applyHighlightResult(provider: 0, highlights: highlights, rangeToHighlight: range)
    func capture(at text: String) -> CaptureName? {
        let location = (source as NSString).range(of: text).location
        return container.runsIn(range: NSRange(location: location, length: 1)).first?.value?.capture
    }
    #expect(capture(at: "Heading") == .textTitle)
    #expect(capture(at: "Setext heading") == .textTitle)
    #expect(capture(at: "bold") == .textStrong)
    #expect(capture(at: "italic") == .textEmphasis)
    #expect(capture(at: "code") == .textLiteral)
    #expect(capture(at: "link") == .textReference)
    #expect(capture(at: "https") == .textURI)
    #expect(capture(at: "- List") == .punctuationSpecial)
    #expect(capture(at: "> Quote") == .punctuationSpecial)
    #expect(capture(at: "let value") == .keyword)
    #expect(capture(at: "hello") == .string)
    #expect(capture(at: "const value") == .keyword)
    #expect(capture(at: "42") == .number)
    #expect(capture(at: "Plain") == nil)

    let theme = ProjectEditorView(editor: ProjectEditor()).theme
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    #expect(NSFontManager.shared.traits(of: theme.fontFor(for: .textTitle, from: font)).contains(.boldFontMask))
    #expect(NSFontManager.shared.traits(of: theme.fontFor(for: .textStrong, from: font)).contains(.boldFontMask))
    #expect(NSFontManager.shared.traits(of: theme.fontFor(for: .textEmphasis, from: font)).contains(.italicFontMask))
    #expect(theme.colorFor(.textURI) == theme.commands.color)
    #expect(theme.colorFor(.textLiteral) == theme.strings.color)
}

@Test("Unwrapped editor can scroll horizontally to the end of a long line")
@MainActor
func editorHorizontalScrolling() throws {
    let configuration = SourceEditorConfiguration(appearance: .init(
        theme: ProjectEditorView(editor: ProjectEditor()).theme,
        font: .monospacedSystemFont(ofSize: 12, weight: .regular), wrapLines: false))
    let controller = TextViewController(string: String(repeating: "long line ", count: 50),
                                        language: .markdown, configuration: configuration,
                                        cursorPositions: [], highlightProviders: [])
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentViewController = controller
    for _ in 0..<3 {
        controller.view.layoutSubtreeIfNeeded()
        controller.textView.layoutManager.layoutLines()
        controller.textView.updateFrameIfNeeded()
    }
    let scroll = try #require(controller.scrollView)
    #expect(controller.textView.frame.width > scroll.contentSize.width)
    var destination = scroll.contentView.bounds
    destination.origin.x = controller.textView.frame.maxX
    scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(destination).origin)
    scroll.reflectScrolledClipView(scroll.contentView)
    #expect(scroll.contentView.bounds.minX > 0)
    let lastCharacter = try #require(controller.textView.layoutManager.rectForOffset(controller.textView.textStorage.length - 2))
    #expect(lastCharacter.maxX <= scroll.contentView.bounds.maxX - controller.textView.textInsets.right + 1)
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

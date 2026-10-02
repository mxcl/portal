#if os(macOS)
import Foundation
import AppKit
import CodeEditLanguages
import CodeEditTextView
@testable import CodeEditSourceEditor
import Testing
@testable import gitdiff
import SwiftUI
@testable import PortalApp
@testable import PortalCore

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

@Test("Editor applies syntax colors with either scroll preview setting", arguments: [false, true])
@MainActor
func editorVisibleHighlighting(showMinimap: Bool) async throws {
    let theme = ProjectEditorView(editor: ProjectEditor()).theme
    let controller = TextViewController(string: "let value = 42", language: .swift,
        configuration: .init(appearance: .init(theme: theme,
            font: .monospacedSystemFont(ofSize: 12, weight: .regular), wrapLines: false), peripherals: .init(showMinimap: showMinimap)),
        cursorPositions: [])
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentViewController = controller
    controller.view.layoutSubtreeIfNeeded()
    controller.textView.layoutManager.layoutLines()
    controller.textView.updateFrameIfNeeded()
    let deadline = Date().addingTimeInterval(2)
    func keywordColor() -> NSColor? {
        controller.textView.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }
    while keywordColor() != theme.keywords.color && Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(keywordColor() == theme.keywords.color)
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
    #expect(scroll.usesPredominantAxisScrolling)
    #expect(controller.textView.frame.width > scroll.contentSize.width)
    var destination = scroll.contentView.bounds
    destination.origin.x = controller.textView.frame.maxX
    scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(destination).origin)
    scroll.reflectScrolledClipView(scroll.contentView)
    #expect(scroll.contentView.bounds.minX > 0)
    let lastCharacter = try #require(controller.textView.layoutManager.rectForOffset(controller.textView.textStorage.length - 2))
    #expect(lastCharacter.maxX <= scroll.contentView.bounds.maxX - controller.textView.textInsets.right + 1)
}

@Test("Minimap stays fixed throughout a horizontal scroll")
@MainActor
func editorMinimapStaysFixed() throws {
    let controller = TextViewController(
        string: String(repeating: String(repeating: "long line ", count: 50) + "\n", count: 30), language: .markdown,
        configuration: .init(appearance: .init(theme: ProjectEditorView(editor: ProjectEditor()).theme,
            font: .monospacedSystemFont(ofSize: 12, weight: .regular), wrapLines: false)),
        cursorPositions: [], highlightProviders: [])
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentViewController = controller
    for _ in 0..<3 {
        controller.view.layoutSubtreeIfNeeded()
        controller.textView.layoutManager.layoutLines()
        controller.textView.updateFrameIfNeeded()
    }
    let minimap = try #require(controller.minimapView)
    let scroll = try #require(controller.scrollView)
    func x() -> CGFloat { minimap.convert(minimap.bounds, to: scroll).minX }
    let initial = x()
    #expect(minimap.frame.width > 0)
    #expect(initial > 0)
    let minimapPoint = minimap.convert(NSPoint(x: minimap.bounds.midX, y: minimap.bounds.midY), to: controller.view)
    let hitView = try #require(controller.view.hitTest(minimapPoint))
    #expect(hitView.isDescendant(of: minimap))
    scroll.contentView.scroll(to: NSPoint(x: 100, y: 0))
    scroll.reflectScrolledClipView(scroll.contentView)
    let during = x()
    controller.view.layoutSubtreeIfNeeded()
    let after = x()
    #expect(during == initial)
    #expect(after == initial)
    let initialFrame = minimap.convert(minimap.bounds, to: scroll)
    let verticalScroller = try #require(scroll.verticalScroller)
    let horizontalScroller = try #require(scroll.horizontalScroller)
    #expect(!initialFrame.intersects(verticalScroller.frame))
    #expect(!initialFrame.intersects(horizontalScroller.frame))
    scroll.contentView.scroll(to: NSPoint(x: 200, y: 100))
    #expect(minimap.convert(minimap.bounds, to: scroll) == initialFrame)
    controller.view.layoutSubtreeIfNeeded()
    #expect(minimap.convert(minimap.bounds, to: scroll) == initialFrame)
    window.setContentSize(NSSize(width: 700, height: 400))
    controller.view.layoutSubtreeIfNeeded()
    let resizedFrame = minimap.convert(minimap.bounds, to: scroll)
    #expect(resizedFrame.minX > initialFrame.minX)
    #expect(resizedFrame.maxX <= scroll.bounds.maxX)
}

@Test("CodeEdit receives a component color for its minimap brightness calculation")
@MainActor
func editorBackgroundColor() {
    let background = ProjectEditorView(editor: ProjectEditor()).theme.background
    #expect(background.type == .componentBased)
    #expect((0...1).contains(background.brightnessComponent))
}

@Test("Open editor refreshes its entire palette when appearance changes")
@MainActor
func editorAppearanceChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    _ = try Git.run(["init", "-q", root.path])
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("plain text\n".utf8).write(to: root.appendingPathComponent("a.txt"))
    let editor = ProjectEditor()
    editor.connect(root)
    editor.open("a.txt")
    let deadline = Date().addingTimeInterval(5)
    while !editor.canEdit && editor.error == nil && Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(editor.canEdit)
    editor.text = "unsaved draft\n"
    let host = NSHostingController(rootView: ProjectEditorView(editor: editor).environment(\.colorScheme, .light))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentViewController = host
    func findEditor(_ view: NSView) -> TextView? {
        if let editor = view as? TextView { return editor }
        return view.subviews.lazy.compactMap { findEditor($0) }.first
    }
    var originalTextView: TextView?
    for scheme in [ColorScheme.light, .dark, .light] {
        host.rootView = ProjectEditorView(editor: editor).environment(\.colorScheme, scheme)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let textView = try #require(findEditor(host.view))
        if let originalTextView { #expect(textView === originalTextView) }
        else { originalTextView = textView }
        let background = try #require(textView.enclosingScrollView?.backgroundColor.usingColorSpace(.deviceRGB))
        #expect((background.brightnessComponent < 0.5) == (scheme == .dark))
        let foreground = try #require(textView.textColor.usingColorSpace(.deviceRGB))
        #expect((foreground.brightnessComponent > 0.5) == (scheme == .dark))
        #expect(textView.string == "unsaved draft\n")
    }
    #expect(editor.isDirty)
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
@Test("Editor opens README and restores each project's last file across editor sessions")
@MainActor
func editorRestoresSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "editor-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    let projects = [root.appendingPathComponent("one"), root.appendingPathComponent("two")]
    for project in projects {
        _ = try Git.run(["init", "-q", project.path])
        for file in ["README.md", "other.txt"] {
            try Data(file.utf8).write(to: project.appendingPathComponent(file))
        }
    }
    func loaded(_ editor: ProjectEditor, path: String) async throws {
        let deadline = Date().addingTimeInterval(5)
        while (editor.path != path || !editor.canEdit) && editor.error == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(editor.path == path)
        try #require(editor.canEdit)
    }
    let editor = ProjectEditor(defaults: defaults)
    editor.connect(projects[0])
    try await loaded(editor, path: "README.md")
    editor.open("other.txt")
    try await loaded(editor, path: "other.txt")
    editor.connect(projects[1])
    try await loaded(editor, path: "README.md")
    let reopened = ProjectEditor(defaults: defaults)
    reopened.connect(projects[0])
    try await loaded(reopened, path: "other.txt")
    reopened.connect(projects[1])
    try await loaded(reopened, path: "README.md")
    try FileManager.default.removeItem(at: projects[0].appendingPathComponent("other.txt"))
    reopened.connect(projects[0])
    try await loaded(reopened, path: "README.md")
    // An explicit diff-file open must win over the pending initial selection.
    reopened.connect(projects[1])
    reopened.open("other.txt")
    try await loaded(reopened, path: "other.txt")
}

@Test("Diff filenames open the working copy and preserve history selection", arguments: ["file.txt", "", "/dev/null"])
@MainActor
func editorOpensDiffFile(newPath: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("project")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try Git.run(["init", "-q", project.path])
    try Data("working copy\n".utf8).write(to: project.appendingPathComponent("file.txt"))
    let model = AppModel(connectToHelper: false)
    model.configuration = AppConfiguration(root: root.path, machine: "test",
        folders: [SyncFolder(name: "project", isLocal: true, availableLocally: true)])
    model.localProjects = ["project": PeerProject(name: "project", placement: .checkedOut)]
    model.selectedProjectName = "project"
    model.selectedCommitID = "selected-history-entry"
    model.selectedTab = .diff
    let file = DiffFile(oldPath: newPath == "file.txt" ? "old.txt" : "file.txt",
                        newPath: newPath, hunks: [], isRenamed: newPath == "file.txt")
    model.openDiffFile(file)
    #expect(model.selectedTab == .editor)
    #expect(model.availableTabs.contains(.editor))
    #expect(model.selectedCommitID == "selected-history-entry")
    #expect(model.editor.path == "file.txt")
    let deadline = Date().addingTimeInterval(5)
    while !model.editor.canEdit && model.editor.error == nil && Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(model.editor.canEdit)
    #expect(model.editor.text == "working copy\n")
    model.editor.text = "unsaved draft"
    model.selectedTab = .diff
    model.openDiffFile(file)
    #expect(model.selectedTab == .editor)
    #expect(model.editor.text == "unsaved draft")
    model.editor.discard()
    model.localProjects = [:]
    model.selectedTab = .diff
    model.openDiffFile(file)
    #expect(model.selectedTab == .diff)
}
@Test("Diff filenames render distinct idle, hover, and pressed states", arguments: [ColorScheme.light, .dark])
@MainActor
func diffFilenameFeedback(scheme: ColorScheme) throws {
    func render(hovered: Bool, pressed: Bool) throws -> NSBitmapImageRep {
        let image = ImageRenderer(content: Text("Sources/File.swift")
            .font(.headline).foregroundColor(scheme == .dark ? .white : .black)
            .modifier(DiffFileButtonFeedback(isHovered: hovered, isPressed: pressed))
            .padding(8).background(scheme == .dark ? Color.black : .white)
            .environment(\.colorScheme, scheme))
        return NSBitmapImageRep(cgImage: try #require(image.cgImage))
    }
    let idle = try render(hovered: false, pressed: false)
    let hover = try render(hovered: true, pressed: false)
    let pressed = try render(hovered: true, pressed: true)
    #expect(idle.pixelsWide == hover.pixelsWide && hover.pixelsWide == pressed.pixelsWide)
    #expect(idle.pixelsHigh == hover.pixelsHigh && hover.pixelsHigh == pressed.pixelsHigh)
    #expect(idle.tiffRepresentation != hover.tiffRepresentation)
    #expect(hover.tiffRepresentation != pressed.tiffRepresentation)
}
#endif

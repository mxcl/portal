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
    #expect(scroll is EditorScrollView)
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

@Test("Trackpad scrolling stays on its initial axis through drift and momentum")
@MainActor
func editorScrollAxisLock() throws {
    let scroll = EditorScrollView()
    func send(x: Int32, y: Int32, phase: Int64 = 0, momentum: Int64 = 0) throws -> NSEvent {
        let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                          wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
        cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        let event = try #require(NSEvent(cgEvent: cgEvent))
        let result = scroll.axisLockedEvent(event)
        // Filtering must not mutate the event delivered to other responders.
        #expect(event.scrollingDeltaX == CGFloat(x))
        #expect(event.scrollingDeltaY == CGFloat(y))
        return result
    }
    // A horizontal start remains horizontal even when the finger drifts vertically.
    var event = try send(x: 20, y: 5, phase: 1)
    #expect(event.scrollingDeltaX == 20 && event.scrollingDeltaY == 0)
    event = try send(x: 5, y: 20, phase: 2)
    #expect(event.scrollingDeltaX == 5 && event.scrollingDeltaY == 0)
    _ = try send(x: 0, y: 0, phase: 4)
    event = try send(x: 5, y: 20, momentum: 1)
    #expect(event.scrollingDeltaX == 5 && event.scrollingDeltaY == 0)
    _ = try send(x: 0, y: 0, momentum: 3)
    // A new gesture can choose the other axis; zero-delta starts don't choose it.
    _ = try send(x: 0, y: 0, phase: 1)
    event = try send(x: 5, y: 20, phase: 2)
    #expect(event.scrollingDeltaX == 0 && event.scrollingDeltaY == 20)
    event = try send(x: 20, y: 5, phase: 2)
    #expect(event.scrollingDeltaX == 0 && event.scrollingDeltaY == 5)
    _ = try send(x: 0, y: 0, phase: 8)
    event = try send(x: 20, y: 5, phase: 1)
    #expect(event.scrollingDeltaX == 20 && event.scrollingDeltaY == 0)
    // Ordinary wheel events keep their native behavior.
    event = try send(x: 10, y: 20)
    #expect(event.scrollingDeltaX == 10 && event.scrollingDeltaY == 20)
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

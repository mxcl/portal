#if os(macOS)
import AppKit
import Foundation
import PortalCore
import QuartzCore
import SwiftUI

private typealias TerminalBlock = CommandLifecycle.Block

enum BackgroundBlurEffect: String, CaseIterable {
    case original
    case contentColumn

    static let defaultsKey = "backgroundBlurEffect"

    static var preferred: Self {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init) ?? .contentColumn
    }

    var title: String {
        switch self {
        case .original: "Dusk Theme"
        case .contentColumn: "Dawn Theme"
        }
    }
}

private enum FindResultTarget: Equatable {
    case command
    case output
}

private struct FindResult: Equatable {
    let blockID: UUID
    let target: FindResultTarget
    let range: NSRange

    static func == (lhs: FindResult, rhs: FindResult) -> Bool {
        lhs.blockID == rhs.blockID
            && lhs.target == rhs.target
            && lhs.range.location == rhs.range.location
            && lhs.range.length == rhs.range.length
    }
}

enum TahoeGlassPalette {
    static func tint(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return (isDark ? NSColor.black : NSColor(white: 0.6, alpha: 1))
                .withAlphaComponent(isDark ? dark : light)
        }
    }

    static let standaloneSpaceBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .clear : NSColor(white: 0.6, alpha: 0.06)
    }

    static func standaloneCommandBackground(darkOpacity: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? .black.withAlphaComponent(darkOpacity) : .textBackgroundColor.withAlphaComponent(0.18)
        }
    }

    static let windowTintStart = tint(light: 0.02, dark: 0.30)
    static let windowTintMid = tint(light: 0.01, dark: 0.26)
    static let windowTintEnd = tint(light: 0, dark: 0.24)
    static let topBarTint = tint(light: 0.04, dark: 0.26)
    static let emptyBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .clear : NSColor(white: 0.97, alpha: 1)
    }
    static let commandBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .clear : .textBackgroundColor
    }
    static var failedCommandBackground: NSColor {
        NSColor.textBackgroundColor.blended(withFraction: 0.08, of: .systemRed) ?? .textBackgroundColor
    }
    static let hairline = NSColor.separatorColor
    static let titleText = NSColor.secondaryLabelColor
    static let titleTextActive = NSColor.labelColor
    static let titleSegmentHoverFill = NSColor.labelColor.withAlphaComponent(0.045)
}

private func mutedGitStatusColor(_ color: NSColor) -> NSColor {
    color.blended(withFraction: 0.1, of: .tertiaryLabelColor)
        ?? color.withAlphaComponent(0.75)
}

func appearanceAlpha(_ color: NSColor, _ alpha: CGFloat) -> NSColor {
    NSColor(name: nil) { appearance in
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.withAlphaComponent(alpha)
        }
        return resolved
    }
}

private func hostPrefixAttributedString(
    _ hostPrefix: String,
    color: NSColor
) -> NSAttributedString {
    NSAttributedString(
        string: hostPrefix.uppercased(),
        attributes: [
            .font: NSFont.systemFont(ofSize: 8, weight: .semibold),
            .foregroundColor: appearanceAlpha(color, 0.34)
        ]
    )
}

private final class SeparatorView: NSView {
    weak var blockAbove: BlockView? { didSet { needsDisplay = true } }
    weak var blockBelow: BlockView? { didSet { needsDisplay = true } }

    var hasFailedNeighbor: Bool {
        blockAbove?.hasFailed == true || blockBelow?.hasFailed == true
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Match a thin NSSplitView divider over the same opaque content background.
        if blockAbove?.usesPortalMaterials != true && blockBelow?.usesPortalMaterials != true {
            TahoeGlassPalette.commandBackground.setFill()
            bounds.fill()
        }
        NSColor.separatorColor.setFill()
        bounds.fill()
        if hasFailedNeighbor {
            NSColor.systemRed.withAlphaComponent(0.08).setFill()
            bounds.fill()
        }
    }
}

private final class NonHitTestingView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class NonHitTestingVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class TerminalBarMaterialView: NSGlassEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        style = .regular
        cornerRadius = 0
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // Keep glass's tighter blur while counteracting its white wash in dark mode.
        tintColor = isDark ? NSColor.black.withAlphaComponent(0.2) : nil
    }
}

private final class SessionPickerView: NSView {
    private enum Direction: Equatable {
        case up, down, left, right
    }

    private enum Selection: Equatable {
        case existing(SessionRef)
        case newSession(SessionLocation)
    }

    weak var sessionPickerStack: NSStackView?
    weak var commandInputView: NSTextView?
    private var selection: Selection?

    static func interactiveControlHitTestingSelfTest() -> Bool {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
        let picker = SessionPickerView(frame: NSRect(x: 20, y: 20, width: 40, height: 40))
        let stack = NSStackView(frame: picker.bounds)
        let header = NSView(frame: picker.bounds)
        let button = SessionHeaderAddButton(
            sessionRef: SessionRef(location: .sshHost("test"), sessionID: "first"),
            hostName: "test"
        )
        let replacement = SessionHeaderAddButton(
            sessionRef: SessionRef(location: .sshHost("test"), sessionID: "second"),
            hostName: "test"
        )
        button.frame = NSRect(x: 10, y: 10, width: 20, height: 20)
        picker.sessionPickerStack = stack
        container.addSubview(picker)
        picker.addSubview(stack)
        stack.addArrangedSubview(header)
        header.addSubview(button)
        return container.hitTest(NSPoint(x: 40, y: 40)) === button
            && picker.selection(for: button) == picker.selection(for: replacement)
    }

    static func keyboardNavigationSelfTest() -> Bool {
        let frames = [
            NSRect(x: 0, y: 0, width: 80, height: 80),
            NSRect(x: 100, y: 0, width: 80, height: 80),
            NSRect(x: 0, y: 100, width: 80, height: 80),
            NSRect(x: 100, y: 100, width: 80, height: 80),
            NSRect(x: 0, y: 200, width: 20, height: 20),
        ]
        return destination(from: 0, moving: .right, in: frames) == 1
            && destination(from: 0, moving: .left, in: frames) == nil
            && destination(from: 0, moving: .down, in: frames) == nil
            && destination(from: 1, moving: .up, in: frames) == 3
            && destination(from: 3, moving: .left, in: frames) == 2
            && destination(from: 2, moving: .up, in: frames) == 4
            && destination(from: 4, moving: .up, in: frames) == nil
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01, frame.contains(point) else { return nil }
        let localPoint = convert(point, from: superview)
        return headerButton(at: localPoint)
            ?? candidateButton(at: localPoint)
    }

    private func headerButton(at point: NSPoint) -> SessionHeaderAddButton? {
        sessionPickerStack?.layoutSubtreeIfNeeded()
        for row in sessionPickerStack?.arrangedSubviews.reversed() ?? [] {
            for case let button as SessionHeaderAddButton in row.subviews.reversed() {
                let buttonPoint = button.convert(point, from: self)
                if button.bounds.contains(buttonPoint) {
                    return button
                }
            }
        }
        return nil
    }

    func candidateButton(at point: NSPoint) -> SessionCandidateButton? {
        sessionPickerStack?.layoutSubtreeIfNeeded()
        for row in sessionPickerStack?.arrangedSubviews.reversed() ?? [] {
            for case let button as SessionCandidateButton in row.subviews.reversed() {
                let buttonPoint = button.convert(point, from: self)
                if button.bounds.contains(buttonPoint) {
                    return button
                }
            }
        }
        return nil
    }
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty else { return false }

        let direction: Direction?
        switch event.keyCode {
        case 126: direction = .up
        case 125: direction = .down
        case 123: direction = .left
        case 124: direction = .right
        default: direction = nil
        }

        if let direction {
            if selection == nil {
                guard direction == .up, let first = initialButton() else { return false }
                select(first)
                return true
            }
            if !moveSelection(direction), direction == .down {
                clearSelection()
                window?.makeFirstResponder(commandInputView)
            }
            return true
        }

        guard let selected = selectedButton() else { return false }
        switch event.keyCode {
        case 36, 49, 76:
            guard let action = selected.action else { return false }
            selected.sendAction(action, to: selected.target)
            return true
        case 53:
            clearSelection()
            return false
        default:
            return false
        }
    }

    func clearSelection() {
        if let selected = selectedButton() {
            setKeyboardSelected(false, on: selected)
        }
        selection = nil
    }

    func restoreSelection() {
        guard selection != nil else { return }
        guard let selected = selectedButton() else {
            selection = nil
            return
        }
        setKeyboardSelected(true, on: selected)
    }

    private func initialButton() -> NSControl? {
        layoutSubtreeIfNeeded()
        let buttons = selectableButtons()
        let existing = buttons.compactMap { $0 as? SessionCandidateButton }
        return (existing.isEmpty ? buttons : existing).min {
            let lhs = $0.convert($0.bounds, to: self).midpoint
            let rhs = $1.convert($1.bounds, to: self).midpoint
            return lhs.y == rhs.y ? lhs.x < rhs.x : lhs.y < rhs.y
        }
    }

    private func moveSelection(_ direction: Direction) -> Bool {
        layoutSubtreeIfNeeded()
        let buttons = selectableButtons()
        guard let selected = selectedButton(),
              let current = buttons.firstIndex(where: { $0 === selected })
        else {
            clearSelection()
            return false
        }
        let frames = buttons.map { $0.convert($0.bounds, to: self) }
        guard let destination = Self.destination(from: current, moving: direction, in: frames)
        else { return false }
        select(buttons[destination])
        return true
    }

    private func select(_ button: NSControl) {
        if let selected = selectedButton() {
            setKeyboardSelected(false, on: selected)
        }
        selection = selection(for: button)
        setKeyboardSelected(true, on: button)
        window?.makeFirstResponder(button)
    }

    private func selectedButton() -> NSControl? {
        guard let selection else { return nil }
        return selectableButtons().first { self.selection(for: $0) == selection }
    }

    private func selectableButtons() -> [NSControl] {
        sessionPickerStack?.arrangedSubviews.flatMap { row in
            row.subviews.compactMap { view in
                if let button = view as? SessionCandidateButton { return button }
                if let button = view as? SessionHeaderAddButton { return button }
                return nil
            }
        } ?? []
    }

    private func selection(for button: NSControl) -> Selection? {
        if let button = button as? SessionCandidateButton { return .existing(button.sessionRef) }
        if let button = button as? SessionHeaderAddButton { return .newSession(button.sessionRef.location) }
        return nil
    }

    private func setKeyboardSelected(_ selected: Bool, on button: NSControl) {
        (button as? SessionCandidateButton)?.isKeyboardSelected = selected
        (button as? SessionHeaderAddButton)?.isKeyboardSelected = selected
    }

    private static func destination(
        from current: Int,
        moving direction: Direction,
        in frames: [NSRect]
    ) -> Int? {
        let origin = frames[current].midpoint
        return frames.indices.filter { index in
            guard index != current else { return false }
            let point = frames[index].midpoint
            switch direction {
            case .up: return point.y > origin.y
            case .down: return point.y < origin.y
            case .left: return point.x < origin.x && point.y == origin.y
            case .right: return point.x > origin.x && point.y == origin.y
            }
        }.min { lhs, rhs in
            score(frames[lhs].midpoint, from: origin, moving: direction)
                < score(frames[rhs].midpoint, from: origin, moving: direction)
        }
    }

    private static func score(_ point: NSPoint, from origin: NSPoint, moving direction: Direction) -> CGFloat {
        let dx = abs(point.x - origin.x)
        let dy = abs(point.y - origin.y)
        let primary = direction == .left || direction == .right ? dx : dy
        let orthogonal = direction == .left || direction == .right ? dy : dx
        return primary + orthogonal * 2
    }
}

private extension NSRect {
    var midpoint: NSPoint { NSPoint(x: midX, y: midY) }
}

private final class CommandInputTextView: NSTextView {
    static let minimumVisibleHeight: CGFloat = 64
    static let maximumVisibleLineCount = 15

    private struct MutedCompletionPreview {
        let text: String
        let characterLocation: Int
    }

    private var mutedCompletionPreview: MutedCompletionPreview?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configurePlainTextInput()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configurePlainTextInput()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configurePlainTextInput()
    }

    override func paste(_ sender: Any?) {
        paste(from: .general)
    }

    private func paste(from pasteboard: NSPasteboard) {
        guard let text = pasteboard.string(forType: .string) else {
            NSSound.beep()
            return
        }

        resetPlainTextAttributes()
        insertText(text, replacementRange: selectedRange())
        normalizePlainTextStorage()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEditable else {
            NSSound.beep()
            return
        }
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawMutedCompletionPreview()
    }

    func resetPlainTextAttributes() {
        typingAttributes = commandTextAttributes
    }

    func normalizePlainTextStorage() {
        let range = NSRange(location: 0, length: (string as NSString).length)
        guard range.length > 0 else {
            resetPlainTextAttributes()
            return
        }
        textStorage?.setAttributes(commandTextAttributes, range: range)
        resetPlainTextAttributes()
    }

    func renderMutedCompletionPreview(_ text: String, afterCharacterLocation characterLocation: Int) {
        normalizePlainTextStorage()
        if text.isEmpty {
            clearMutedCompletionPreview()
            return
        }

        let textLength = (string as NSString).length
        let boundedLocation = min(max(0, characterLocation), textLength)
        mutedCompletionPreview = MutedCompletionPreview(
            text: text,
            characterLocation: boundedLocation
        )
        resetPlainTextAttributes()
        needsDisplay = true
    }

    func renderCompletionPreview(_ suggestion: CompletionSuggestion, replacementRange: NSRange) {
        let input = string as NSString
        guard replacementRange.location >= 0,
              replacementRange.location + replacementRange.length <= input.length
        else {
            clearMutedCompletionPreview()
            return
        }

        let existing = input.substring(with: replacementRange)
        let insertText = suggestion.insertText as NSString
        let typedPrefixLength = Self.commonPrefixLength(existing, suggestion.insertText)
        let mutedText = typedPrefixLength < insertText.length
            ? insertText.substring(from: typedPrefixLength)
            : ""
        renderMutedCompletionPreview(
            mutedText,
            afterCharacterLocation: replacementRange.location + typedPrefixLength
        )
    }

    static func completionPreviewPreservesCaretSelfTest() -> Bool {
        let view = CommandInputTextView(frame: .zero)
        view.string = "exi"
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.renderCompletionPreview(
            CompletionSuggestion(
                displayText: "exit",
                insertText: "exit",
                description: nil,
                kind: .command,
                priority: 0,
                source: "self-test"
            ),
            replacementRange: NSRange(location: 0, length: 2)
        )
        return view.selectedRange() == NSRange(location: 3, length: 0)
    }

    static func visibleHeight(
        contentHeight: CGFloat,
        lineHeight: CGFloat,
        verticalInset: CGFloat
    ) -> CGFloat {
        min(
            max(minimumVisibleHeight, ceil(contentHeight + verticalInset * 2)),
            ceil(lineHeight * CGFloat(maximumVisibleLineCount) + verticalInset * 2)
        )
    }

    static func expandingHeightSelfTest() -> Bool {
        visibleHeight(contentHeight: 17, lineHeight: 17, verticalInset: 10) == 64 &&
            visibleHeight(contentHeight: 68, lineHeight: 17, verticalInset: 10) == 88 &&
            visibleHeight(contentHeight: 340, lineHeight: 17, verticalInset: 10) == 275
    }

    static func multilinePasteSelfTest() -> Bool {
        let view = CommandInputTextView(frame: .zero)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PortalMultilinePasteSelfTest"))
        defer { pasteboard.releaseGlobally() }
        let command = #"""
        sudo -H /usr/bin/env -i \
          HOME=/var/root TMPDIR=/var/root \
          PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
          /bin/sh -c '
            cd / &&
            mise install --system uv &&
            mise reshim --system
          '
        """#
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        view.paste(from: pasteboard)
        return view.string == command
    }

    func clearMutedCompletionPreview() {
        guard mutedCompletionPreview != nil else { return }
        mutedCompletionPreview = nil
        needsDisplay = true
    }

    private var commandTextAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: textColor ?? NSColor.labelColor
        ]
    }

    private static func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        var length = 0
        var lhsIndex = lhs.startIndex
        var rhsIndex = rhs.startIndex
        while lhsIndex < lhs.endIndex,
              rhsIndex < rhs.endIndex,
              lhs[lhsIndex] == rhs[rhsIndex] {
            length += String(lhs[lhsIndex]).utf16.count
            lhsIndex = lhs.index(after: lhsIndex)
            rhsIndex = rhs.index(after: rhsIndex)
        }
        return length
    }

    private var mutedCompletionTextColor: NSColor {
        (textColor ?? NSColor.labelColor).withAlphaComponent(0.38)
    }

    private func drawMutedCompletionPreview() {
        guard let preview = mutedCompletionPreview,
              let rect = mutedCompletionPreviewRect(afterCharacterLocation: preview.characterLocation)
        else {
            return
        }

        var attributes = commandTextAttributes
        attributes[.foregroundColor] = mutedCompletionTextColor
        (preview.text as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func mutedCompletionPreviewRect(afterCharacterLocation characterLocation: Int) -> NSRect? {
        guard let layoutManager,
              let textContainer
        else {
            return nil
        }

        layoutManager.ensureLayout(for: textContainer)

        let textLength = (string as NSString).length
        let lineHeight = font.map {
            layoutManager.defaultLineHeight(for: $0)
        } ?? 16
        let origin = textContainerOrigin
        let fallbackRect = NSRect(
            x: origin.x,
            y: origin.y,
            width: max(1, bounds.maxX - origin.x),
            height: lineHeight
        )

        guard textLength > 0, layoutManager.numberOfGlyphs > 0 else {
            return fallbackRect
        }

        let boundedLocation = min(max(0, characterLocation), textLength)
        let characterIndex = boundedLocation < textLength ? boundedLocation : textLength - 1
        let glyphIndex = min(
            layoutManager.glyphIndexForCharacter(at: characterIndex),
            max(0, layoutManager.numberOfGlyphs - 1)
        )
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        )
        let x = origin.x + (boundedLocation < textLength ? glyphRect.minX : glyphRect.maxX)
        let y = origin.y + glyphRect.minY
        return NSRect(
            x: x,
            y: y,
            width: max(1, bounds.maxX - x),
            height: max(lineHeight, glyphRect.height)
        )
    }

    private func configurePlainTextInput() {
        isRichText = false
        importsGraphics = false
        usesFontPanel = false
        allowsDocumentBackgroundColorChange = false
        resetPlainTextAttributes()
    }
}

@MainActor
func portalTerminalInputSelfTest() -> Bool {
    CommandInputTextView.multilinePasteSelfTest()
        && TerminalOutputProcessor.terminalResponsesAreImmediateSelfTest()
}

private final class ResizeMetricsTooltipView: NSView {
    private enum Metrics {
        static let horizontalPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 7
        static let minimumHeight: CGFloat = 30
    }

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor

        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.92)
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.horizontalPadding),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.verticalPadding),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.verticalPadding)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(text: String) -> NSSize {
        label.stringValue = text
        let textSize = (text as NSString).size(withAttributes: [
            .font: label.font ?? NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        ])
        return NSSize(
            width: ceil(textSize.width) + Metrics.horizontalPadding * 2,
            height: max(Metrics.minimumHeight, ceil(textSize.height) + Metrics.verticalPadding * 2)
        )
    }
}

private struct ContentColumnBackground: View {
    var body: some View {
        Rectangle()
            .fill(.thinMaterial)
            .backgroundExtensionEffect()
            .ignoresSafeArea()
    }
}

/// The standalone terminal's complete material and tint stack, without its tab chrome.
@MainActor
public func makeTerminalBackgroundView() -> NSView {
    let view = TahoeGlassRootView()
    view.usesPortalMaterials = true
    return view
}

final class TahoeGlassRootView: NSView {
    private let originalMaterialView = NonHitTestingVisualEffectView()
    private let contentColumnMaterialView = NSHostingView(rootView: ContentColumnBackground())
    private let tintView = NonHitTestingView()
    private let originalTintLayer = CAGradientLayer()
    private lazy var contentColumnMaterialConstraints = [
        contentColumnMaterialView.leadingAnchor.constraint(equalTo: leadingAnchor),
        contentColumnMaterialView.trailingAnchor.constraint(equalTo: trailingAnchor),
        contentColumnMaterialView.topAnchor.constraint(equalTo: topAnchor),
        contentColumnMaterialView.bottomAnchor.constraint(equalTo: bottomAnchor)
    ]

    var backgroundBlurEffect = BackgroundBlurEffect.preferred {
        didSet {
            guard backgroundBlurEffect != oldValue else { return }
            updateBackgroundBlurEffect()
        }
    }

    var onAppearanceChange: (() -> Void)?
    var onLayout: (() -> Void)?
    var usesPortalMaterials = false {
        didSet {
            originalMaterialView.blendingMode = usesPortalMaterials ? .behindWindow : .withinWindow
            updateBackgroundBlurEffect()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        originalMaterialView.material = .underWindowBackground
        originalMaterialView.blendingMode = .withinWindow
        originalMaterialView.state = .active
        originalMaterialView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(originalMaterialView, positioned: .below, relativeTo: nil)

        contentColumnMaterialView.translatesAutoresizingMaskIntoConstraints = false

        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = (usesPortalMaterials ? TahoeGlassPalette.standaloneSpaceBackground : TahoeGlassPalette.emptyBackground).cgColor
        tintView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tintView, positioned: .above, relativeTo: originalMaterialView)

        originalTintLayer.colors = [
            TahoeGlassPalette.windowTintStart.cgColor,
            TahoeGlassPalette.windowTintMid.cgColor,
            TahoeGlassPalette.windowTintEnd.cgColor
        ]
        originalTintLayer.locations = [0, 0.48, 1]
        originalTintLayer.startPoint = CGPoint(x: 0, y: 0)
        originalTintLayer.endPoint = CGPoint(x: 1, y: 1)
        tintView.layer?.addSublayer(originalTintLayer)

        NSLayoutConstraint.activate([
            originalMaterialView.leadingAnchor.constraint(equalTo: leadingAnchor),
            originalMaterialView.trailingAnchor.constraint(equalTo: trailingAnchor),
            originalMaterialView.topAnchor.constraint(equalTo: topAnchor),
            originalMaterialView.bottomAnchor.constraint(equalTo: bottomAnchor),

            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintView.topAnchor.constraint(equalTo: topAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        updateBackgroundBlurEffect()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        onLayout?()
        originalTintLayer.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tintView.layer?.backgroundColor = (usesPortalMaterials ? TahoeGlassPalette.standaloneSpaceBackground : TahoeGlassPalette.emptyBackground).cgColor
            originalTintLayer.colors = [
                TahoeGlassPalette.windowTintStart.cgColor,
                TahoeGlassPalette.windowTintMid.cgColor,
                TahoeGlassPalette.windowTintEnd.cgColor
            ]
            updateBackgroundBlurEffect()
            onAppearanceChange?()
        }
    }

    private func updateBackgroundBlurEffect() {
        let matchesWindow = !usesPortalMaterials && effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tintView.layer?.backgroundColor = (usesPortalMaterials ? TahoeGlassPalette.standaloneSpaceBackground : TahoeGlassPalette.emptyBackground).cgColor
        }
        originalMaterialView.isHidden = matchesWindow
        contentColumnMaterialView.isHidden = matchesWindow
        originalTintLayer.isHidden = backgroundBlurEffect != .original
        if matchesWindow { originalTintLayer.isHidden = true }
        switch backgroundBlurEffect {
        case .original:
            NSLayoutConstraint.deactivate(contentColumnMaterialConstraints)
            contentColumnMaterialView.removeFromSuperview()
        case .contentColumn:
            guard contentColumnMaterialView.superview == nil else { return }
            addSubview(contentColumnMaterialView, positioned: .below, relativeTo: tintView)
            NSLayoutConstraint.activate(contentColumnMaterialConstraints)
        }
    }

}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class SelectableBlockTextField: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = true
        isBordered = false
        drawsBackground = false
        backgroundColor = .clear
        focusRingType = .none
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isEditable = false
        isSelectable = true
        isBordered = false
        drawsBackground = false
        backgroundColor = .clear
        focusRingType = .none
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    @objc func copy(_ sender: Any?) {
        guard let selectedText = selectedTextForCopy() else {
            NSSound.beep()
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedText, forType: .string)
    }

    fileprivate func selectedTextForCopy() -> String? {
        guard let editor = currentEditor() else { return nil }
        let selectedRange = editor.selectedRange
        guard selectedRange.length > 0,
              let range = Range(selectedRange, in: editor.string)
        else {
            return nil
        }
        return String(editor.string[range])
    }
}

private final class BlockOutputTextView: NSTextView {
    private static let linkCapsuleColor = NSColor.labelColor.withAlphaComponent(0.10)
    private var linkTrackingArea: NSTrackingArea?
    private var firstMouseLink: (value: Any, characterIndex: Int)?
    var onTerminalMouseEvent: ((NSEvent, NSPoint) -> Bool)?
    private var hoveredLinkRange: NSRange? {
        didSet {
            guard hoveredLinkRange != oldValue else { return }
            if let oldValue, NSMaxRange(oldValue) <= (textStorage?.length ?? 0) {
                layoutManager?.removeTemporaryAttribute(.underlineStyle, forCharacterRange: oldValue)
            }
            if let hoveredLinkRange {
                layoutManager?.addTemporaryAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    forCharacterRange: hoveredLinkRange
                )
            }
            needsDisplay = true
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        firstMouseLink = event.flatMap(link(at:))
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if forwardTerminalMouseEvent(event) {
            firstMouseLink = nil
            return
        }
        let firstMouseLink = firstMouseLink
        super.mouseDown(with: event)
        guard self.firstMouseLink != nil, let firstMouseLink else { return }
        self.firstMouseLink = nil
        clicked(onLink: firstMouseLink.value, at: firstMouseLink.characterIndex)
    }

    override func mouseUp(with event: NSEvent) {
        if !forwardTerminalMouseEvent(event) { super.mouseUp(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if !forwardTerminalMouseEvent(event) { super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if !forwardTerminalMouseEvent(event) { super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        if !forwardTerminalMouseEvent(event) { super.otherMouseDown(with: event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if !forwardTerminalMouseEvent(event) { super.otherMouseUp(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        if !forwardTerminalMouseEvent(event) { super.mouseDragged(with: event) }
    }

    override func rightMouseDragged(with event: NSEvent) {
        if !forwardTerminalMouseEvent(event) { super.rightMouseDragged(with: event) }
    }

    override func otherMouseDragged(with event: NSEvent) {
        if !forwardTerminalMouseEvent(event) { super.otherMouseDragged(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        if !forwardTerminalMouseEvent(event) { super.scrollWheel(with: event) }
    }

    override func didChangeText() {
        hoveredLinkRange = nil
        super.didChangeText()
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let linkTrackingArea {
            removeTrackingArea(linkTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        linkTrackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        // Sticky headers cover output without shrinking its tracking area.
        if let content = window?.contentView {
            let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            guard content.hitTest(point) === self else {
                hoveredLinkRange = nil
                return
            }
        }
        if forwardTerminalMouseEvent(event) {
            hoveredLinkRange = nil
            NSCursor.arrow.set()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        var hoveredRange: NSRange?
        enumerateLinkRects { range, rect in
            if hoveredRange == nil, rect.contains(point) {
                hoveredRange = range
            }
        }
        hoveredLinkRange = hoveredRange
        (hoveredRange == nil ? NSCursor.iBeam : NSCursor.pointingHand).set()
    }

    private func forwardTerminalMouseEvent(_ event: NSEvent) -> Bool {
        onTerminalMouseEvent?(event, convert(event.locationInWindow, from: nil)) == true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredLinkRange = nil
        super.mouseExited(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        Self.linkCapsuleColor.setFill()
        enumerateLinkRects { [hoveredLinkRange] range, rect in
            guard range == hoveredLinkRange else { return }
            let capsuleRect = rect.insetBy(dx: -3, dy: -1)
            guard capsuleRect.intersects(dirtyRect) else { return }
            NSBezierPath(
                roundedRect: capsuleRect,
                xRadius: capsuleRect.height / 2,
                yRadius: capsuleRect.height / 2
            ).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        super.draw(dirtyRect)
    }

    private func enumerateLinkRects(_ body: @escaping (NSRange, NSRect) -> Void) {
        guard let textStorage, let layoutManager, let textContainer else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        layoutManager.ensureLayout(for: textContainer)
        textStorage.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard value != nil else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: textContainer
            ) { [weak self] rect, _ in
                guard let self else { return }
                body(
                    range,
                    rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
                )
            }
        }
    }

    private func link(at event: NSEvent) -> (value: Any, characterIndex: Int)? {
        let point = convert(event.locationInWindow, from: nil)
        var result: (value: Any, characterIndex: Int)?
        enumerateLinkRects { [weak self] range, rect in
            guard result == nil,
                  rect.contains(point),
                  let value = self?.textStorage?.attribute(.link, at: range.location, effectiveRange: nil)
            else {
                return
            }
            result = (value, range.location)
        }
        return result
    }

    override func clicked(onLink link: Any, at charIndex: Int) {
        firstMouseLink = nil
        if let fileLink = link as? Ansi.FileLink {
            followFileLink(fileLink)
            return
        }
        if let url = link as? URL {
            if url.isFileURL {
                followFileLink(Ansi.FileLink(url: url, line: nil))
                return
            }
            NSWorkspace.shared.open(url)
            return
        }
        super.clicked(onLink: link, at: charIndex)
    }

    private func followFileLink(_ link: Ansi.FileLink) {
        if link.isDirectory || !link.isTextFile {
            NSWorkspace.shared.activateFileViewerSelecting([link.url])
        } else {
            openInDefaultEditor(link)
        }
    }

    private func openInDefaultEditor(_ link: Ansi.FileLink) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var arguments = ["-t", link.url.path]
        if let line = link.line {
            arguments += ["--args", "+\(line)"]
        }
        process.arguments = arguments
        try? process.run()
    }

    fileprivate func selectedTextForCopy() -> String? {
        let selectedRange = selectedRange()
        guard selectedRange.length > 0,
              let range = Range(selectedRange, in: string)
        else {
            return nil
        }
        return String(string[range])
    }
}

private final class HoverCopyMarkdownButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { updateHoverAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        image = NSImage(
            systemSymbolName: "square.on.square",
            accessibilityDescription: "Copy Markdown"
        )
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        toolTip = "Copy Markdown"
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.clear.cgColor
        contentTintColor = TahoeGlassPalette.titleText
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    private func updateHoverAppearance() {
        layer?.backgroundColor = (isHovering
            ? NSColor.labelColor.withAlphaComponent(0.10)
            : NSColor.clear
        ).cgColor
        contentTintColor = isHovering ? .labelColor : .secondaryLabelColor
    }
}

private final class TerminalIconButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { updateAppearance() }
    }

    init(symbol: String, label: String) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: label
        )
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        toolTip = label
        setAccessibilityLabel(label)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.clear.cgColor
        contentTintColor = .secondaryLabelColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    private func updateAppearance() {
        layer?.backgroundColor = (isHovering
            ? NSColor.labelColor.withAlphaComponent(0.10)
            : NSColor.clear
        ).cgColor
        contentTintColor = isHovering ? .labelColor : .secondaryLabelColor
    }
}

private final class BlockView: NSView {
    var usesPortalMaterials = false
    private var runningBackground: NSColor {
        usesPortalMaterials ? TahoeGlassPalette.standaloneCommandBackground(darkOpacity: 0.22) : TahoeGlassPalette.commandBackground
    }
    private var completedBackground: NSColor {
        usesPortalMaterials ? TahoeGlassPalette.standaloneCommandBackground(darkOpacity: 0.18) : TahoeGlassPalette.commandBackground
    }
    private var failedBackground: NSColor {
        TahoeGlassPalette.failedCommandBackground
    }

    private enum Metrics {
        static let runningMinimumHeight: CGFloat = 90
    }

    private enum DurationRounding: Equatable {
        case down
        case nearest
    }

    private struct MetadataSegment {
        let text: String
        let color: NSColor
    }

    private let stickyHeader = NSView()
    private let stickyHeaderMaterial = TerminalBarMaterialView()
    private var headerTopConstraint: NSLayoutConstraint!
    private var metadataLeadingConstraint: NSLayoutConstraint!
    private var metadataTopConstraint: NSLayoutConstraint!
    private let commandLabel = SelectableBlockTextField()
    private let metaLabel = SelectableBlockTextField()
    private let outputView = BlockOutputTextView(frame: .zero)
    private let copyMarkdownButton = HoverCopyMarkdownButton(frame: .zero)
    private let scrollToTopButton = TerminalIconButton(symbol: "arrow.up.to.line", label: "Scroll to top of block")
    private let findReticuleLayer = CALayer()
    private var outputHeightConstraint: NSLayoutConstraint?
    private var minimumHeightConstraint: NSLayoutConstraint?
    private var contentBottomConstraint: NSLayoutConstraint?
    private var hasVisibleOutput = false
    private var lastMeasuredOutputWidth: CGFloat = 0
    private var needsOutputHeightMeasurement = true
    private var renderedOutputRevision = -1
    private var lastBlock: TerminalBlock?
    weak var topSeparator: SeparatorView?
    weak var bottomSeparator: SeparatorView?
    var hasFailed: Bool {
        if case .completed(let code) = lastBlock?.state { return code != 0 }
        return false
    }
    private var findSelectionTarget: FindResultTarget?
    private var findSelectionRange: NSRange?

    static func findScrollClearanceSelfTest(topInset: CGFloat, startingOffset: CGFloat) -> Bool {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let document = FlippedDocumentView(frame: NSRect(x: 0, y: 0, width: 600, height: 2_400))
        scrollView.documentView = document
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets.top = topInset
        scrollView.contentView.postsBoundsChangedNotifications = true
        let view = BlockView(frame: NSRect(x: 0, y: 200, width: 600, height: 1_600))
        document.addSubview(view)
        let output = (0..<80).map { "output line \($0)\n" }.joined()
        view.update(with: TerminalBlock(
            id: UUID(), command: "print output", cwd: "/tmp", startedAt: Date(), finishedAt: Date(),
            output: output,
            attributedOutput: NSAttributedString(string: output, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            ]), outputRevision: 1, state: .completed(0)
        ))
        view.layoutSubtreeIfNeeded()
        let range = (output as NSString).range(of: "output line 40")
        view.setFindSelection(target: .output, range: range)
        guard let rect = view.outputRect(for: range) else { return false }
        let match = document.convert(rect, from: view.outputView)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: match.minY + startingOffset))
        view.layoutSubtreeIfNeeded()
        view.scrollFindSelectionToVisible()
        view.layoutSubtreeIfNeeded()
        guard let visibleRect = view.outputRect(for: range) else { return false }
        let visibleMatch = document.convert(visibleRect, from: view.outputView)
        let header = document.convert(view.stickyHeader.bounds, from: view.stickyHeader)
        let viewport = scrollView.contentView.bounds
        return visibleMatch.minY >= max(header.maxY, viewport.minY + topInset) + 7.5
            && visibleMatch.maxY <= viewport.maxY - 7.5
    }

    static func stickyHeaderSelfTest() async -> Bool {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let document = FlippedDocumentView(frame: NSRect(x: 0, y: 0, width: 600, height: 1_200))
        scrollView.documentView = document
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        let block = BlockView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        block.commandLabel.stringValue = "printf 'long output'"
        document.addSubview(block)
        block.layoutSubtreeIfNeeded()
        let outputFrame = block.outputView.frame
        let commandFrame = block.commandLabel.frame
        for inset: CGFloat in [0, 38] {
            scrollView.contentInsets.top = inset
            for scrollY: CGFloat in [0, 100, 580, 700, 0] {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollY - inset))
                block.layoutSubtreeIfNeeded()
                let headerFrame = document.convert(block.stickyHeader.bounds, from: block.stickyHeader)
                let expectedY = min(scrollY, 600 - headerFrame.height)
                guard abs(headerFrame.minY - expectedY) < 0.5,
                      headerFrame.maxY <= 600,
                      block.outputView.frame == outputFrame,
                      block.scrollToTopButton.isHidden == (scrollY == 0) else { return false }
                let buttonCenter = document.convert(
                    NSPoint(x: block.copyMarkdownButton.bounds.midX, y: block.copyMarkdownButton.bounds.midY),
                    from: block.copyMarkdownButton
                )
                guard block.hitTest(buttonCenter) === block.copyMarkdownButton else { return false }
            }
            for blockY: CGFloat in [0, 200] {
                block.setFrameOrigin(NSPoint(x: 0, y: blockY))
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: blockY + 100))
                block.layoutSubtreeIfNeeded()
                guard block.stickyHeader.gestureRecognizers.isEmpty,
                      !block.scrollToTopButton.isHidden,
                      block.scrollToTopButton.image != nil,
                      block.scrollToTopButton.frame.width == block.scrollToTopButton.frame.height else { return false }
                for y in [CGFloat(1), block.scrollToTopButton.bounds.midY, block.scrollToTopButton.bounds.maxY - 1] {
                    let point = document.convert(NSPoint(x: block.scrollToTopButton.bounds.midX, y: y), from: block.scrollToTopButton)
                    guard block.hitTest(point) === block.scrollToTopButton else { return false }
                }
                block.scrollToTopButton.performClick(nil)
                let deadline = Date().addingTimeInterval(2)
                while !block.scrollToTopButton.isHidden && Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                guard abs(scrollView.contentView.bounds.minY - (blockY - inset)) < 0.5,
                      block.headerTopConstraint.constant == 0,
                      block.scrollToTopButton.isHidden else { return false }
            }
            block.setFrameOrigin(.zero)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = scrollView
        defer { window.close() }
        scrollView.contentInsets.top = 0
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 100))
        block.layoutSubtreeIfNeeded()
        for button in [block.copyMarkdownButton, block.scrollToTopButton] {
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            guard let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
            ) else { return false }
            NSCursor.arrow.set()
            block.outputView.mouseMoved(with: event)
            guard NSCursor.current == NSCursor.arrow else { return false }
        }
        block.metaLabel.stringValue = "~/src/av  79.6 ms  3:01 PM"
        for scrollY: CGFloat in [100, -100, 100] {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollY))
            block.layoutSubtreeIfNeeded()
            let metadata = block.metaLabel.convert(block.metaLabel.bounds, to: nil)
            guard let zoom = window.standardWindowButton(.zoomButton) else { return false }
            let button = zoom.convert(zoom.bounds, to: nil)
            if scrollY > 0 {
                guard metadata.minX > button.maxX,
                      abs(metadata.midY - button.midY) < 0.5 else { return false }
            } else {
                guard block.metadataLeadingConstraint.constant == 0,
                      block.metadataTopConstraint.constant == 0 else { return false }
            }
            guard block.commandLabel.frame == commandFrame,
                  block.outputView.frame == outputFrame else { return false }
        }
        for name in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            block.appearance = NSAppearance(named: name)
            for scrollY: CGFloat in [100, -100] {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollY))
                block.layoutSubtreeIfNeeded()
                guard block.stickyHeaderMaterial.isHidden == (scrollY < 0),
                      block.stickyHeaderMaterial.style == .regular,
                      block.stickyHeaderMaterial.tintColor == (name == .darkAqua ? NSColor.black.withAlphaComponent(0.2) : nil),
                      block.stickyHeaderMaterial.frame == block.stickyHeader.bounds else { return false }
            }
        }
        return true
    }

    static func widthReflowSelfTest() -> Bool {
        final class Delegate: NSObject, NSTextViewDelegate {}

        let output = String(
            repeating: "/Users/mxcl/src/av/target/swift/Automic Vault.app/Contents/Resources/AutomicVaultVarlockPlugin: replacing existing signature\n",
            count: 8
        )
        let block = TerminalBlock(
            id: UUID(),
            command: "./scripts/build.sh --run --install",
            cwd: "/tmp",
            startedAt: Date(),
            finishedAt: Date(),
            output: output,
            attributedOutput: NSAttributedString(
                string: output,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]
            ),
            outputRevision: 1,
            state: .completed(0)
        )
        let delegate = Delegate()
        let tab = TerminalTab(title: "Test", delegate: delegate)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 700))
        let content = NSView()
        let tree = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        tree.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        host.addSubview(tree)
        content.addSubview(tab.rootView)
        let fullWidth = content.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        let treeWidth = content.trailingAnchor.constraint(equalTo: tree.leadingAnchor)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            fullWidth,
            tree.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            tree.topAnchor.constraint(equalTo: host.topAnchor),
            tree.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            tree.widthAnchor.constraint(equalToConstant: 300),
            tab.rootView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tab.rootView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tab.rootView.topAnchor.constraint(equalTo: content.topAnchor),
            tab.rootView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        let view = BlockView()
        view.translatesAutoresizingMaskIntoConstraints = false
        tab.stackView.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: tab.stackView.widthAnchor).isActive = true
        view.update(with: block)
        host.layoutSubtreeIfNeeded()
        fullWidth.isActive = false
        treeWidth.isActive = true
        view.needsLayout = true
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        tab.stackView.needsLayout = true
        tab.rootView.layoutSubtreeIfNeeded()
        tab.scrollView.layoutSubtreeIfNeeded()
        tab.scrollView.documentView?.layoutSubtreeIfNeeded()

        for height in [900, 500, 700] {
            tab.rootView.isHidden = true
            host.setFrameSize(NSSize(width: 1_000, height: CGFloat(height)))
            host.layoutSubtreeIfNeeded()
            tab.rootView.isHidden = false
            host.layoutSubtreeIfNeeded()
            tab.scrollView.documentView?.layoutSubtreeIfNeeded()
            guard view.bounds.height < (view.outputHeightConstraint?.constant ?? 0) + 100 else {
                return false
            }
        }

        guard let textContainer = view.outputView.textContainer,
              let layoutManager = view.outputView.layoutManager,
              let constrainedHeight = view.outputHeightConstraint?.constant
        else { return false }
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = ceil(layoutManager.usedRect(for: textContainer).height)
        return constrainedHeight >= usedHeight && view.outputView.bounds.height >= usedHeight
            && view.bounds.height < usedHeight + 100
    }

    var hidesLiveDuration = false {
        didSet {
            guard hidesLiveDuration != oldValue, let lastBlock else { return }
            update(with: lastBlock)
        }
    }

    var onCopyMarkdown: (() -> Void)?
    var onTerminalMouseEvent: ((NSEvent, NSPoint) -> Bool)? {
        didSet { outputView.onTerminalMouseEvent = onTerminalMouseEvent }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.borderWidth = 0
        layer?.backgroundColor = runningBackground.cgColor
        findReticuleLayer.isHidden = true
        findReticuleLayer.opacity = 0
        findReticuleLayer.borderWidth = 0
        findReticuleLayer.cornerRadius = 3
        findReticuleLayer.backgroundColor = NSColor.findHighlightColor.withAlphaComponent(0.45).cgColor
        findReticuleLayer.zPosition = 1
        layer?.addSublayer(findReticuleLayer)

        commandLabel.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        commandLabel.textColor = .labelColor
        commandLabel.lineBreakMode = .byWordWrapping
        commandLabel.maximumNumberOfLines = 0

        metaLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingMiddle
        metaLabel.maximumNumberOfLines = 1

        outputView.isEditable = false
        outputView.isSelectable = true
        outputView.drawsBackground = false
        outputView.linkTextAttributes = [:]
        outputView.textContainerInset = NSSize(width: 0, height: 0)
        outputView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        outputView.textColor = .labelColor
        outputView.isHorizontallyResizable = false
        outputView.isVerticallyResizable = true
        outputView.textContainer?.lineFragmentPadding = 0
        outputView.textContainer?.lineBreakMode = .byCharWrapping
        outputView.textContainer?.widthTracksTextView = true
        outputView.textContainer?.heightTracksTextView = false
        outputView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )

        copyMarkdownButton.target = self
        copyMarkdownButton.action = #selector(copyMarkdown)
        copyMarkdownButton.setButtonType(.momentaryPushIn)
        copyMarkdownButton.translatesAutoresizingMaskIntoConstraints = false

        scrollToTopButton.target = self
        scrollToTopButton.action = #selector(scrollToTopClicked)
        scrollToTopButton.isHidden = true
        scrollToTopButton.translatesAutoresizingMaskIntoConstraints = false

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(scrollToTopButton)
        header.addSubview(metaLabel)
        header.addSubview(copyMarkdownButton)
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        commandLabel.translatesAutoresizingMaskIntoConstraints = false
        commandLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stickyHeader.translatesAutoresizingMaskIntoConstraints = false
        stickyHeader.wantsLayer = true
        stickyHeaderMaterial.isHidden = true
        stickyHeaderMaterial.autoresizingMask = [.width, .height]
        stickyHeader.addSubview(stickyHeaderMaterial)
        stickyHeader.addSubview(header)
        stickyHeader.addSubview(commandLabel)
        let headerSpace = NSView()
        headerSpace.translatesAutoresizingMaskIntoConstraints = false
        let content = NSStackView(views: [headerSpace, outputView])
        content.orientation = .vertical
        content.spacing = 0
        content.alignment = .leading
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        addSubview(stickyHeader)
        headerTopConstraint = stickyHeader.topAnchor.constraint(equalTo: topAnchor)
        metadataLeadingConstraint = metaLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor)
        metadataTopConstraint = metaLabel.topAnchor.constraint(equalTo: header.topAnchor)
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification, object: nil
        )

        let outputHeightConstraint = outputView.heightAnchor.constraint(equalToConstant: 0)
        self.outputHeightConstraint = outputHeightConstraint
        let minimumHeightConstraint = heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.runningMinimumHeight)
        self.minimumHeightConstraint = minimumHeightConstraint
        let contentBottomConstraint = content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        contentBottomConstraint.isActive = false
        self.contentBottomConstraint = contentBottomConstraint

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: topAnchor),
            headerSpace.heightAnchor.constraint(equalTo: stickyHeader.heightAnchor),
            headerTopConstraint,
            stickyHeader.leadingAnchor.constraint(equalTo: leadingAnchor),
            stickyHeader.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.leadingAnchor.constraint(equalTo: stickyHeader.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: stickyHeader.trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: stickyHeader.topAnchor, constant: 8),
            commandLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            commandLabel.topAnchor.constraint(equalTo: header.bottomAnchor),
            commandLabel.bottomAnchor.constraint(equalTo: stickyHeader.bottomAnchor, constant: -6),
            header.heightAnchor.constraint(equalToConstant: 28),
            metadataLeadingConstraint,
            metadataTopConstraint,
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollToTopButton.leadingAnchor, constant: -8),
            scrollToTopButton.topAnchor.constraint(equalTo: header.topAnchor),
            scrollToTopButton.trailingAnchor.constraint(equalTo: copyMarkdownButton.leadingAnchor, constant: -4),
            scrollToTopButton.widthAnchor.constraint(equalToConstant: 28),
            scrollToTopButton.heightAnchor.constraint(equalToConstant: 28),
            copyMarkdownButton.topAnchor.constraint(equalTo: header.topAnchor),
            copyMarkdownButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            copyMarkdownButton.bottomAnchor.constraint(lessThanOrEqualTo: header.bottomAnchor),
            commandLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            outputView.widthAnchor.constraint(equalTo: content.widthAnchor),
            copyMarkdownButton.widthAnchor.constraint(equalToConstant: 36),
            copyMarkdownButton.heightAnchor.constraint(equalToConstant: 28),
            outputHeightConstraint,
            minimumHeightConstraint
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if let lastBlock { update(with: lastBlock) }
        }
    }

    func update(with block: TerminalBlock, now: Date = Date()) {
        // Cached terminals can receive history updates outside their drawing context.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            updateContent(with: block, now: now)
        }
    }

    private func updateContent(with block: TerminalBlock, now: Date) {
        lastBlock = block
        topSeparator?.needsDisplay = true
        bottomSeparator?.needsDisplay = true
        commandLabel.stringValue = block.command
        hasVisibleOutput = !block.output.isEmpty
        outputView.isHidden = !hasVisibleOutput
        let output = block.output.isEmpty ? Ansi.emptyAttributedOutput() : block.attributedOutput
        if block.outputRevision != renderedOutputRevision {
            outputView.textStorage?.setAttributedString(output)
            resetOutputViewport()
            renderedOutputRevision = block.outputRevision
            needsOutputHeightMeasurement = true
        }
        updateOutputHeight()

        var metadata = [
            MetadataSegment(text: displayCwd(block.cwd), color: .secondaryLabelColor)
        ]
        switch block.state {
        case .running:
            layer?.backgroundColor = runningBackground.cgColor
            if !hidesLiveDuration {
                metadata.append(MetadataSegment(
                    text: liveDurationText(startedAt: block.startedAt, now: now),
                    color: .tertiaryLabelColor
                ))
            }
            minimumHeightConstraint?.constant = Metrics.runningMinimumHeight
            contentBottomConstraint?.isActive = hasVisibleOutput
        case .completed(let code):
            minimumHeightConstraint?.constant = 0
            contentBottomConstraint?.isActive = true
            layer?.backgroundColor = (code == 0
                ? completedBackground
                : failedBackground
            ).cgColor
            if let duration = durationText(for: block) {
                metadata.append(MetadataSegment(text: duration, color: .tertiaryLabelColor))
            }
            if let timestamp = completionTimestampText(for: block) {
                metadata.append(MetadataSegment(text: timestamp, color: .tertiaryLabelColor))
            }
            if code != 0 {
                metadata.append(MetadataSegment(text: "exit \(code)", color: .systemRed))
            }
        }
        updateStickyHeader()
        metaLabel.attributedStringValue = attributedMetadata(metadata)
        applyFindSelectionAppearance(bounce: false)
    }

    func setFindSelection(target: FindResultTarget?, range: NSRange? = nil, bounce: Bool = false) {
        let didChange = findSelectionTarget != target
            || findSelectionRange?.location != range?.location
            || findSelectionRange?.length != range?.length
        guard didChange || bounce else { return }
        findSelectionTarget = target
        findSelectionRange = range
        if target == nil, let lastBlock {
            findReticuleLayer.isHidden = true
            renderedOutputRevision = -1
            update(with: lastBlock)
            return
        }
        applyFindSelectionAppearance(bounce: bounce)
    }

    func scrollFindSelectionToVisible() {
        guard let target = findSelectionTarget,
              let range = findSelectionRange
        else {
            scrollToVisible(bounds)
            return
        }

        switch target {
        case .command:
            scrollToVisible(convert(commandLabel.bounds.insetBy(dx: 0, dy: -8), from: commandLabel))
        case .output:
            layoutSubtreeIfNeeded()
            let rect = outputRect(for: range) ?? outputView.bounds
            var targetRect = convert(rect.insetBy(dx: 0, dy: -8), from: outputView)
            // Block coordinates are unflipped: reserve space above the match for its sticky header.
            targetRect.size.height += stickyHeader.bounds.height
            scrollToVisible(targetRect)
        }
    }

    override func layout() {
        super.layout()
        updateStickyHeader()
        if abs(outputView.bounds.width - lastMeasuredOutputWidth) > 0.5 {
            needsOutputHeightMeasurement = true
            updateOutputHeight()
        }
    }

    @objc private func scrollToTopClicked() {
        scrollToBlockTop(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func scrollToBlockTop(animated: Bool) {
        guard let scrollView = enclosingScrollView,
              let document = scrollView.documentView else { return }
        let clipView = scrollView.contentView
        var target = clipView.bounds
        target.origin.y = document.convert(bounds, from: self).minY - scrollView.contentInsets.top
        let origin = clipView.constrainBoundsRect(target).origin
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clipView.animator().setBoundsOrigin(origin)
            }
        } else {
            clipView.setBoundsOrigin(origin)
        }
    }

    @objc private func scrollBoundsChanged(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView,
              clipView === enclosingScrollView?.contentView else { return }
        updateStickyHeader()
        layoutSubtreeIfNeeded()
    }

    private func updateStickyHeader() {
        guard let scrollView = enclosingScrollView else { return }
        let clipView = scrollView.contentView
        let viewportTop = convert(
            NSPoint(x: clipView.bounds.minX, y: clipView.bounds.minY + scrollView.contentInsets.top),
            from: clipView
        ).y
        // Keep the header inside its own block so the next command pushes it away.
        let offset = min(max(0, bounds.maxY - viewportTop), max(0, bounds.height - stickyHeader.bounds.height))
        if let header = metaLabel.superview {
            // Account for the pending sticky offset before Auto Layout moves the header.
            let row = convert(header.bounds, from: header)
                .offsetBy(dx: 0, dy: headerTopConstraint.constant - offset)
            var leading: CGFloat = 0
            var top: CGFloat = 0
            let metadataCenter = row.maxY + metaLabel.alignmentRectInsets.top - metaLabel.bounds.height / 2
            for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window?.standardWindowButton(type), !button.isHiddenOrHasHiddenAncestor else { continue }
                let frame = convert(button.bounds, from: button)
                if row.intersects(frame) {
                    leading = max(leading, frame.maxX + 8 - row.minX)
                    top = metadataCenter - frame.midY
                }
            }
            if metadataLeadingConstraint.constant != leading {
                metadataLeadingConstraint.constant = leading
            }
            if metadataTopConstraint.constant != top {
                metadataTopConstraint.constant = top
            }
        }
        if headerTopConstraint.constant != offset {
            headerTopConstraint.constant = offset
        }
        stickyHeaderMaterial.isHidden = offset <= 0
        scrollToTopButton.isHidden = offset <= 0
    }

    @objc private func copyMarkdown() { onCopyMarkdown?() }

    fileprivate func selectedTextForCopy(firstResponder: NSResponder) -> String? {
        if let text = firstResponder as? NSText {
            if commandLabel.currentEditor() === text {
                return commandLabel.selectedTextForCopy()
            }
            if metaLabel.currentEditor() === text {
                return metaLabel.selectedTextForCopy()
            }
        }

        if firstResponder === outputView {
            return outputView.selectedTextForCopy()
        }

        return nil
    }

    func terminalContentSize(fitting viewportSize: NSSize) -> NSSize {
        layoutSubtreeIfNeeded()
        return NSSize(
            width: max(0, viewportSize.width - max(0, bounds.width - outputView.bounds.width)),
            height: max(0, viewportSize.height - max(0, bounds.height - outputView.bounds.height))
        )
    }

    func terminalCell(at point: NSPoint, rows: Int, cols: Int) -> (column: Int, row: Int)? {
        guard outputView.bounds.contains(point), let font = outputView.font else { return nil }
        let origin = outputView.textContainerOrigin
        let x = point.x - origin.x
        let y = point.y - origin.y
        guard x >= 0, y >= 0 else { return nil }
        let characterWidth = max(1, ceil(("W" as NSString).size(withAttributes: [.font: font]).width))
        let lineHeight = max(1, ceil(font.ascender - font.descender + font.leading))
        return (
            min(cols, Int(x / characterWidth) + 1),
            min(rows, Int(y / lineHeight) + 1)
        )
    }

    private func updateOutputHeight() {
        guard let textContainer = outputView.textContainer,
              let layoutManager = outputView.layoutManager
        else {
            return
        }
        guard hasVisibleOutput else {
            outputHeightConstraint?.constant = 0
            lastMeasuredOutputWidth = outputView.bounds.width
            needsOutputHeightMeasurement = false
            return
        }
        let availableWidth = max(1, outputView.bounds.width)
        guard needsOutputHeightMeasurement || abs(availableWidth - lastMeasuredOutputWidth) > 0.5 else {
            return
        }
        textContainer.containerSize = NSSize(
            width: availableWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        outputHeightConstraint?.constant = ceil(usedRect.height)
        resetOutputViewport()
        lastMeasuredOutputWidth = availableWidth
        needsOutputHeightMeasurement = false
    }

    private func resetOutputViewport() {
        outputView.setBoundsOrigin(.zero)
    }

    private func applyFindSelectionAppearance(bounce: Bool) {
        guard let target = findSelectionTarget,
              let range = findSelectionRange,
              let lastBlock
        else {
            findReticuleLayer.isHidden = true
            return
        }

        let textColor = NSColor(calibratedWhite: 0.10, alpha: 1)
        let highlightColor = NSColor.findHighlightColor
        commandLabel.attributedStringValue = normalCommandAttributedString(lastBlock.command)
        outputView.textStorage?.setAttributedString(lastBlock.attributedOutput)
        var reticuleRect: NSRect?
        switch target {
        case .command:
            let command = NSMutableAttributedString(attributedString: commandLabel.attributedStringValue)
            if isValidRange(range, inLength: command.length) {
                command.addAttributes([
                    .backgroundColor: highlightColor,
                    .foregroundColor: textColor
                ], range: range)
                commandLabel.attributedStringValue = command
                reticuleRect = commandRect(for: range)
            }
        case .output:
            let output = NSMutableAttributedString(attributedString: lastBlock.attributedOutput)
            if isValidRange(range, inLength: output.length) {
                output.addAttributes([
                    .backgroundColor: highlightColor,
                    .foregroundColor: textColor
                ], range: range)
                outputView.textStorage?.setAttributedString(output)
                reticuleRect = outputRect(for: range)
            }
        }

        guard let reticuleRect else {
            findReticuleLayer.isHidden = true
            return
        }
        updateFindReticule(
            frame: reticuleRect.insetBy(dx: -2, dy: -2),
            from: target == .command ? commandLabel : outputView,
            bounce: bounce
        )
    }

    private func updateFindReticule(frame: NSRect, from view: NSView, bounce: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        findReticuleLayer.frame = convert(frame, from: view)
        findReticuleLayer.isHidden = !bounce
        findReticuleLayer.opacity = 0
        CATransaction.commit()

        guard bounce else { return }
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1.18, 1.04, 1.0]
        scale.keyTimes = [0, 0.58, 1]

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0.65, 0.35, 0.0]
        opacity.keyTimes = scale.keyTimes

        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = 0.34
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = true
        findReticuleLayer.add(group, forKey: "findBounce")
    }

    private func normalCommandAttributedString(_ command: String) -> NSAttributedString {
        NSAttributedString(
            string: command,
            attributes: [
                .font: commandLabel.font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
        )
    }

    private func commandRect(for range: NSRange) -> NSRect? {
        textRect(
            for: range,
            in: commandLabel.stringValue,
            font: commandLabel.font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            width: commandLabel.bounds.width
        )
    }

    private func outputRect(for range: NSRange) -> NSRect? {
        guard let textContainer = outputView.textContainer,
              let layoutManager = outputView.layoutManager,
              isValidRange(range, inLength: outputView.textStorage?.length ?? 0)
        else {
            return nil
        }
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += outputView.textContainerOrigin.x
        rect.origin.y += outputView.textContainerOrigin.y
        return rect
    }

    private func textRect(for range: NSRange, in text: String, font: NSFont, width: CGFloat) -> NSRect? {
        let textStorage = NSTextStorage(string: text, attributes: [.font: font])
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byWordWrapping
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)
        guard isValidRange(range, inLength: textStorage.length) else { return nil }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
    }

    private func isValidRange(_ range: NSRange, inLength length: Int) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length > 0
            && range.location + range.length <= length
    }

    private func durationText(for block: TerminalBlock) -> String? {
        guard let finishedAt = block.finishedAt else {
            return nil
        }
        let seconds = max(0, finishedAt.timeIntervalSince(block.startedAt))
        return Self.durationText(seconds: seconds, rounding: .nearest)
    }

    private func completionTimestampText(for block: TerminalBlock) -> String? {
        guard let finishedAt = block.finishedAt else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.dateStyle = Calendar.autoupdatingCurrent.isDateInToday(finishedAt) ? .none : .short
        formatter.timeStyle = .short
        return formatter.string(from: finishedAt)
    }

    static func liveDurationRefreshInterval(startedAt: Date, now: Date, refreshInterval: TimeInterval) -> TimeInterval {
        let seconds = max(0, now.timeIntervalSince(startedAt))
        let displayScale = seconds < 1 ? 1000.0 : 1.0
        let displayValue = seconds * displayScale
        let step = significantFigureStep(for: displayValue)
        let nextDisplayValue = (floor(displayValue / step) + 1) * step
        return max(refreshInterval, (nextDisplayValue - displayValue) / displayScale)
    }

    private func attributedMetadata(_ metadata: [MetadataSegment]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let font = metaLabel.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)

        for (index, segment) in metadata.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(
                    string: "  ",
                    attributes: [
                        .font: font,
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                ))
            }
            output.append(NSAttributedString(
                string: segment.text,
                attributes: [
                    .font: font,
                    .foregroundColor: segment.color
                ]
            ))
        }

        return output
    }

    private func displayCwd(_ cwd: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if cwd == home {
            return "~"
        }
        if cwd.hasPrefix(home + "/") {
            return "~" + String(cwd.dropFirst(home.count))
        }
        return cwd
    }

    private func liveDurationText(startedAt: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(startedAt))
        return Self.durationText(seconds: seconds, rounding: .down)
    }

    private static func durationText(seconds: TimeInterval, rounding: DurationRounding) -> String {
        if seconds < 1 {
            let milliseconds = seconds * 1000
            let roundedMilliseconds = significantFigureValue(milliseconds, rounding: rounding)
            if rounding == .nearest, roundedMilliseconds >= 1000 {
                return "\(significantFiguresText(seconds, rounding: rounding))s"
            }
            return "\(significantFiguresText(milliseconds, rounding: rounding)) ms"
        }

        return "\(significantFiguresText(seconds, rounding: rounding))s"
    }

    private static func significantFiguresText(_ value: Double, rounding: DurationRounding) -> String {
        let rounded = significantFigureValue(value, rounding: rounding)
        guard rounded > 0 else {
            return "0.00"
        }

        let exponent = floor(log10(rounded))
        let decimals = max(0, 2 - Int(exponent))
        return String(format: "%.\(decimals)f", rounded)
    }

    private static func significantFigureValue(_ value: Double, rounding: DurationRounding) -> Double {
        guard value > 0 else {
            return 0
        }

        let step = significantFigureStep(for: value)
        switch rounding {
        case .down:
            return floor(value / step) * step
        case .nearest:
            return (value / step).rounded() * step
        }
    }

    private static func significantFigureStep(for value: Double) -> Double {
        guard value > 0 else {
            return 0.01
        }
        let exponent = floor(log10(value))
        return pow(10, exponent - 2)
    }
}

@MainActor
func portalFindScrollClearanceSelfTest(topInset: CGFloat, startingOffset: CGFloat) -> Bool {
    BlockView.findScrollClearanceSelfTest(topInset: topInset, startingOffset: startingOffset)
}

@MainActor
func portalStickyBlockHeaderSelfTest() async -> Bool {
    await BlockView.stickyHeaderSelfTest()
}

@MainActor
func portalCommandBarOverlaySelfTest() async -> Bool {
    let delegate = TerminalViewController()
    let tab = TerminalTab(title: "Test", delegate: delegate)
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
    host.addSubview(tab.rootView)
    NSLayoutConstraint.activate([
        tab.rootView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        tab.rootView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        tab.rootView.topAnchor.constraint(equalTo: host.topAnchor),
        tab.rootView.bottomAnchor.constraint(equalTo: host.bottomAnchor)
    ])
    let history = NSView()
    history.translatesAutoresizingMaskIntoConstraints = false
    history.heightAnchor.constraint(equalToConstant: 1_200).isActive = true
    tab.stackView.addArrangedSubview(history)
    tab.setToolbarInset(38)
    for name in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
        host.appearance = NSAppearance(named: name)
        host.layoutSubtreeIfNeeded()
        guard tab.commandBarMaterial.style == .regular,
              tab.commandBarMaterial.tintColor == (name == .darkAqua ? NSColor.black.withAlphaComponent(0.2) : nil) else { return false }
    }
    for height: CGFloat in [44, 120, 44] {
        tab.commandInputHeightConstraint?.constant = height
        host.layoutSubtreeIfNeeded()
        tab.rootView.layoutSubtreeIfNeeded()
        guard let document = tab.scrollView.documentView else { return false }
        let bottomInset = tab.scrollView.contentInsets.bottom
        tab.scrollView.tile()
        guard let scroller = tab.scrollView.verticalScroller else { return false }
        let scrollerFrame = tab.rootView.convert(scroller.bounds, from: scroller)
        guard abs(scrollerFrame.minY - tab.sessionPickerView.frame.maxY) < 0.5,
              abs(scrollerFrame.maxY - (tab.rootView.bounds.maxY - 38)) < 0.5 else { return false }
        guard bottomInset > height,
              abs(bottomInset - tab.sessionPickerView.frame.maxY) < 0.5,
              tab.scrollView.frame == tab.rootView.bounds,
              tab.commandBarMaterial.frame.minY == tab.rootView.bounds.minY,
              !tab.commandBarMaterial.isHidden else { return false }
        tab.scrollView.contentView.scroll(to: NSPoint(
            x: 0, y: document.bounds.height + bottomInset - tab.scrollView.contentView.bounds.height
        ))
        guard tab.scrollToBottomButton.isHidden else { return false }
        let historyBottom = tab.rootView.convert(NSPoint(x: 0, y: document.bounds.maxY), from: document).y
        guard abs(historyBottom - tab.sessionPickerView.frame.maxY) < 0.5 else { return false }
        tab.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 100))
        guard tab.scrollView.documentVisibleRect.maxY < document.bounds.height,
              !tab.scrollToBottomButton.isHidden,
              tab.scrollToBottomButton.image != nil else { return false }
        host.layoutSubtreeIfNeeded()
        let button = tab.scrollToBottomButton
        guard abs(button.frame.width - button.frame.height) < 0.5 else { return false }
        for y in [CGFloat(1), button.bounds.midY, button.bounds.maxY - 1] {
            let point = button.convert(NSPoint(x: button.bounds.midX, y: y), to: host)
            guard host.hitTest(point) === button else { return false }
        }
        tab.scrollToBottomButton.performClick(nil)
        let deadline = Date().addingTimeInterval(2)
        while !tab.isScrolledToBottom && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard tab.isScrolledToBottom, tab.scrollToBottomButton.isHidden else { return false }
    }
    tab.commandBarView.isHidden = true
    tab.updateCommandBarInset()
    return tab.scrollView.contentInsets.bottom == 0
        && tab.scrollView.scrollerInsets.bottom == 0
        && tab.commandBarMaterial.isHidden
        && tab.documentMinimumHeightConstraint.constant == -38
}

@MainActor
func portalToolbarScrollRegionSelfTest() -> Bool {
    let delegate = TerminalViewController()
    let tab = TerminalTab(title: "Test", delegate: delegate)
    for inset: CGFloat in [0, 38, 0] {
        tab.setToolbarInset(inset)
        guard tab.documentMinimumHeightConstraint.constant + tab.scrollView.contentInsets.top + tab.scrollView.contentInsets.bottom == 0,
              tab.scrollView.scrollerInsets.top == 0 else { return false }
    }
    return withExtendedLifetime(delegate) { true }
}

func portalFailedCommandDividersSelfTest() -> Bool {
    let view = BlockView()
    let top = SeparatorView(), bottom = SeparatorView(), vertical = SeparatorView()
    top.blockBelow = view
    bottom.blockAbove = view
    view.topSeparator = top
    view.bottomSeparator = bottom
    var block = TerminalBlock(
        id: UUID(), command: "false", cwd: "/tmp", startedAt: Date(),
        finishedAt: nil, output: "", attributedOutput: NSAttributedString(string: ""),
        outputRevision: 0, state: .running
    )
    for (state, failed): (TerminalBlock.State, Bool) in [
        (.running, false), (.completed(0), false), (.completed(127), true), (.completed(0), false)
    ] {
        block.state = state
        view.update(with: block)
        guard top.hasFailedNeighbor == failed, bottom.hasFailedNeighbor == failed,
              !vertical.hasFailedNeighbor else { return false }
    }
    return true
}

func portalBlockWidthReflowSelfTest() -> Bool {
    BlockView.widthReflowSelfTest()
}

func portalDetachedBlockAppearanceSelfTest() -> Bool {
    let view = BlockView()
    var block = TerminalBlock(
        id: UUID(), command: "false", cwd: "/tmp", startedAt: Date(),
        finishedAt: Date(), output: "", attributedOutput: NSAttributedString(string: ""),
        outputRevision: 0, state: .completed(127)
    )
    for (name, standalone) in [NSAppearance.Name.darkAqua, .aqua].flatMap({ name in [false, true].map { (name, $0) } }) {
        view.usesPortalMaterials = standalone
        view.appearance = NSAppearance(named: name)
        let otherAppearance = NSAppearance(named: name == .aqua ? .darkAqua : .aqua)!
        for state: TerminalBlock.State in [.running, .completed(0), .completed(127)] {
            block.state = state
            var expected: CGColor?
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                if case .completed(127) = state {
                    expected = TahoeGlassPalette.failedCommandBackground.cgColor
                } else {
                    let opacity: CGFloat
                    if case .running = state { opacity = 0.22 } else { opacity = 0.18 }
                    expected = (standalone ? TahoeGlassPalette.standaloneCommandBackground(darkOpacity: opacity) : TahoeGlassPalette.commandBackground).cgColor
                }
            }
            otherAppearance.performAsCurrentDrawingAppearance {
                view.update(with: block)
            }
            guard view.layer?.backgroundColor == expected else { return false }
        }
    }
    return true
}

private enum TerminalMouseEncoder {
    private enum Action {
        case press(Int)
        case release(Int)
        case motion(Int?)
        case wheel(Int)
    }

    static func sequence(
        for event: NSEvent,
        column: Int,
        row: Int,
        trackingMode: Ansi.MouseTrackingMode,
        usesSGR: Bool
    ) -> Data? {
        guard let action = action(for: event) else { return nil }
        if case .motion(let button) = action {
            guard trackingMode == .any || (trackingMode == .button && button != nil) else { return nil }
        }

        let modifiers = modifierCode(for: event.modifierFlags)
        let code: Int
        let isRelease: Bool
        switch action {
        case .press(let button):
            code = button + modifiers
            isRelease = false
        case .release(let button):
            code = (usesSGR ? button : 3) + modifiers
            isRelease = true
        case .motion(let button):
            code = (button ?? 3) + 32 + modifiers
            isRelease = false
        case .wheel(let direction):
            code = 64 + direction + modifiers
            isRelease = false
        }

        if usesSGR {
            return sgrSequence(code: code, column: column, row: row, isRelease: isRelease)
        }
        return legacySequence(code: code, column: min(223, column), row: min(223, row))
    }

    static func selfTest() -> Bool {
        guard let click = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            return false
        }
        return sequence(for: click, column: 12, row: 3, trackingMode: .normal, usesSGR: true)
                == Data("\u{1B}[<0;12;3M".utf8)
            && legacySequence(code: 0, column: 100, row: 7)
                == Data([0x1B, 0x5B, 0x4D, 32, 132, 39])
    }

    private static func action(for event: NSEvent) -> Action? {
        switch event.type {
        case .leftMouseDown: return .press(0)
        case .rightMouseDown: return .press(2)
        case .otherMouseDown: return terminalButton(event.buttonNumber).map(Action.press)
        case .leftMouseUp: return .release(0)
        case .rightMouseUp: return .release(2)
        case .otherMouseUp: return terminalButton(event.buttonNumber).map(Action.release)
        case .leftMouseDragged: return .motion(0)
        case .rightMouseDragged: return .motion(2)
        case .otherMouseDragged: return .motion(terminalButton(event.buttonNumber))
        case .mouseMoved: return .motion(nil)
        case .scrollWheel:
            let vertical = event.scrollingDeltaY
            guard vertical != 0 else { return nil }
            return .wheel(vertical > 0 ? 0 : 1)
        default:
            return nil
        }
    }

    private static func terminalButton(_ buttonNumber: Int) -> Int? {
        buttonNumber == 2 ? 1 : nil
    }

    private static func modifierCode(for flags: NSEvent.ModifierFlags) -> Int {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        return (flags.contains(.shift) ? 4 : 0)
            + (flags.contains(.option) ? 8 : 0)
            + (flags.contains(.control) ? 16 : 0)
    }

    private static func sgrSequence(code: Int, column: Int, row: Int, isRelease: Bool) -> Data {
        Data("\u{1B}[<\(code);\(column);\(row)\(isRelease ? "m" : "M")".utf8)
    }

    private static func legacySequence(code: Int, column: Int, row: Int) -> Data {
        Data([0x1B, 0x5B, 0x4D, UInt8(code + 32), UInt8(column + 32), UInt8(row + 32)])
    }
}

private final class PtyPassthroughView: NSView {
    var onInput: ((String) -> Void)?
    var onInterrupt: (() -> Void)?
    var usesApplicationCursorKeys: (() -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let sequence = terminalSequence(for: event) else {
            super.keyDown(with: event)
            return
        }
        handleTerminalSequence(sequence)
    }

    @objc func paste(_ sender: Any?) {
        paste(from: .general)
    }

    private func paste(from pasteboard: NSPasteboard) {
        guard let text = pasteboard.string(forType: .string) else {
            NSSound.beep()
            return
        }
        onInput?(text)
    }

    private func handleTerminalSequence(_ sequence: String) {
        if sequence == "\u{3}" {
            onInterrupt?()
            return
        }
        onInput?(sequence)
    }

    static func passthroughRoutingSelfTest() -> Bool {
        let view = PtyPassthroughView(frame: .zero)
        var inputs: [String] = []
        var interruptCount = 0
        view.onInput = { inputs.append($0) }
        view.onInterrupt = { interruptCount += 1 }

        guard view.responds(to: #selector(NSText.paste(_:))) else { return false }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PortalPassthroughRoutingSelfTest"))
        pasteboard.clearContents()
        pasteboard.setString("pasted\ntext", forType: .string)
        view.paste(from: pasteboard)
        guard inputs == ["pasted\ntext"], interruptCount == 0 else { return false }

        view.handleTerminalSequence("x")
        guard inputs == ["pasted\ntext", "x"], interruptCount == 0 else { return false }

        view.handleTerminalSequence("\u{3}")
        return inputs == ["pasted\ntext", "x"] && interruptCount == 1
    }

    override func cancelOperation(_ sender: Any?) {
        onInterrupt?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    private func terminalSequence(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            return nil
        }
        if flags.contains(.control), event.charactersIgnoringModifiers?.lowercased() == "c" {
            return "\u{3}"
        }

        // Navigation key character payloads can already contain ESC bytes; use hardware key codes.
        switch event.keyCode {
        case 126:
            return cursorKey(normal: "\u{1B}[A", application: "\u{1B}OA")
        case 125:
            return cursorKey(normal: "\u{1B}[B", application: "\u{1B}OB")
        case 124:
            return cursorKey(normal: "\u{1B}[C", application: "\u{1B}OC")
        case 123:
            return cursorKey(normal: "\u{1B}[D", application: "\u{1B}OD")
        case 115:
            return "\u{1B}[H"
        case 119:
            return "\u{1B}[F"
        case 116:
            return "\u{1B}[5~"
        case 121:
            return "\u{1B}[6~"
        case 117:
            return "\u{1B}[3~"
        default:
            break
        }

        if let special = event.charactersIgnoringModifiers?.unicodeScalars.first?.value,
           special >= 0xF700,
           special <= 0xF8FF {
            return nil
        }

        return event.characters?.isEmpty == false ? event.characters : nil
    }

    private func cursorKey(normal: String, application: String) -> String {
        usesApplicationCursorKeys?() == true ? application : normal
    }
}

final class SessionCandidateButton: NSButton {
    let sessionRef: SessionRef
    let sessionID: String
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { updateAppearance() }
    }
    var isKeyboardSelected = false {
        didSet { updateAppearance() }
    }

    init(
        sessionRef: SessionRef,
        title: String,
        subtitle: String?,
        metadata: String,
        icon: NSImage? = nil,
        usesDefaultIcon: Bool = true
    ) {
        self.sessionRef = sessionRef
        self.sessionID = sessionRef.sessionID
        super.init(frame: .zero)
        self.title = ""
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryPushIn)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.clear.cgColor
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        iconView.image = icon ?? (usesDefaultIcon
            ? Bundle.main.image(forResource: NSImage.Name("session-icon"))
            : nil)
        iconView.image?.isTemplate = icon == nil && usesDefaultIcon
        iconView.isHidden = iconView.image == nil
        iconView.contentTintColor = TahoeGlassPalette.titleTextActive
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.maximumNumberOfLines = 1
        detailLabel.isHidden = subtitle?.isEmpty != false
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailLabel)

        metaLabel.stringValue = metadata
        metaLabel.font = .systemFont(ofSize: 12, weight: .medium)
        metaLabel.textColor = .tertiaryLabelColor
        metaLabel.lineBreakMode = .byWordWrapping
        metaLabel.maximumNumberOfLines = 2
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metaLabel)

        let hasSubtitle = subtitle?.isEmpty == false
        let detailTopConstraint = detailLabel.topAnchor.constraint(
            equalTo: titleLabel.bottomAnchor,
            constant: 3
        )
        let metaTopAnchor = hasSubtitle ? detailLabel.bottomAnchor : titleLabel.bottomAnchor
        let metaTopConstraint = metaLabel.topAnchor.constraint(
            equalTo: metaTopAnchor,
            constant: hasSubtitle ? 3 : 6
        )

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 82),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.topAnchor.constraint(equalTo: titleLabel.topAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),

            titleLabel.leadingAnchor.constraint(
                equalTo: iconView.image == nil ? leadingAnchor : iconView.trailingAnchor,
                constant: iconView.image == nil ? 12 : 10
            ),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailTopConstraint,

            metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            metaTopConstraint
        ])

        setAccessibilityValue(metadata)
        let subtitleText = subtitle ?? ""
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)

        titleLabel.stringValue = title
        detailLabel.stringValue = subtitleText

        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func updateAppearance() {
        layer?.backgroundColor = isHovering || isKeyboardSelected
            ? TahoeGlassPalette.titleSegmentHoverFill.cgColor
            : NSColor.clear.cgColor
        layer?.borderWidth = isKeyboardSelected ? 2 : 0
        layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
        iconView.contentTintColor = isHovering || isKeyboardSelected
            ? NSColor.labelColor
            : TahoeGlassPalette.titleTextActive
    }
}

final class SessionHeaderAddButton: NSButton {
    let sessionRef: SessionRef
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { updateAppearance() }
    }
    var isKeyboardSelected = false {
        didSet { updateAppearance() }
    }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }

    init(sessionRef: SessionRef, hostName: String) {
        self.sessionRef = sessionRef
        super.init(frame: .zero)
        title = ""
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 5
        toolTip = "New session on \(hostName)"
        setAccessibilityLabel(toolTip)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 20),
            heightAnchor.constraint(equalToConstant: 20)
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        (contentTintColor ?? .controlTextColor).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: bounds.midX - 3, y: bounds.midY))
        path.line(to: NSPoint(x: bounds.midX + 3, y: bounds.midY))
        path.move(to: NSPoint(x: bounds.midX, y: bounds.midY - 3))
        path.line(to: NSPoint(x: bounds.midX, y: bounds.midY + 3))
        path.stroke()
    }

    private func updateAppearance() {
        layer?.backgroundColor = isHovering || isKeyboardSelected
            ? TahoeGlassPalette.titleSegmentHoverFill.cgColor
            : NSColor.clear.cgColor
        layer?.borderWidth = isKeyboardSelected ? 2 : 0
        layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
        contentTintColor = isHovering || isKeyboardSelected
            ? TahoeGlassPalette.titleTextActive
            : appearanceAlpha(TahoeGlassPalette.titleTextActive, 0.5)
        needsDisplay = true
    }
}

final class SessionCandidateRowView: NSView {
    private enum Metrics {
        static let spacing: CGFloat = 10
        static let height: CGFloat = 82
    }

    private let buttons: [SessionCandidateButton]
    private let columnCount: Int

    init(buttons: [SessionCandidateButton], columnCount: Int = 4) {
        self.buttons = buttons
        self.columnCount = columnCount
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for button in buttons {
            button.translatesAutoresizingMaskIntoConstraints = true
            addSubview(button)
        }
        heightAnchor.constraint(equalToConstant: Metrics.height).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Metrics.height)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01, bounds.contains(point) else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func layout() {
        super.layout()
        let availableWidth = max(0, bounds.width - Metrics.spacing * CGFloat(columnCount - 1))
        let columnWidth = floor(availableWidth / CGFloat(columnCount))

        for (index, button) in buttons.enumerated() {
            let x = CGFloat(index) * (columnWidth + Metrics.spacing)
            button.frame = NSRect(
                x: x,
                y: 0,
                width: columnWidth,
                height: Metrics.height
            )
        }
    }
}

private final class TerminalTabRootView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

@MainActor
private final class TerminalTab: NSObject {
    let id = UUID()
    var sessionRef: SessionRef
    var sessionID: String {
        get { sessionRef.sessionID }
        set { sessionRef.sessionID = newValue }
    }
    var session: PtySession
    let commandLifecycle: CommandLifecycle
    let outputProcessor = TerminalOutputProcessor()
    let rootView = TerminalTabRootView()
    let scrollView = NSScrollView()
    let stackView = NSStackView()
    let sessionPickerView = SessionPickerView()
    let sessionPickerStack = NSStackView()
    let inputView = CommandInputTextView(frame: .zero)
    let statusLineStack = NSStackView()
    let statusLabel = NSTextField(labelWithString: "Starting shell...")
    let commandSeparator = SeparatorView()
    let commandBarView = NSView()
    let commandBarMaterial = TerminalBarMaterialView()
    let findCloseButton = TerminalIconButton(symbol: "multiply", label: "Close Find")
    let scrollToBottomButton = TerminalIconButton(symbol: "arrow.down.to.line", label: "Scroll to bottom")
    let completionPendingLine = NSView()
    let ptyPassthroughView = PtyPassthroughView(frame: .zero)
    var title: String
    var hasUnviewedCompletion = false

    var documentMinimumHeightConstraint: NSLayoutConstraint!
    var sessionPickerHeightConstraint: NSLayoutConstraint?
    var commandInputHeightConstraint: NSLayoutConstraint?
    var interruptedBlockID: UUID?

    var blocks: [TerminalBlock] { commandLifecycle.state.blocks }
    var blockViews: [UUID: BlockView] = [:]
    var pendingBlockViewUpdates = Set<UUID>()
    var isBlockViewUpdateScheduled = false
    var activeBlockID: UUID? { commandLifecycle.state.activeBlockID }
    var pendingBlockID: UUID? { commandLifecycle.state.pendingBlockID }
    var currentCwd: String { commandLifecycle.state.currentCwd }
    var isScrolledToBottom: Bool {
        scrollView.contentView.bounds.maxY >= (scrollView.documentView?.bounds.height ?? 0)
            + scrollView.contentInsets.bottom - 1
    }

    var isScrollToBottomScheduled = false
    var isShellReady: Bool { commandLifecycle.state.isShellReady }
    var isReplayingHistory: Bool { commandLifecycle.state.isReplayingHistory }
    var hasExited: Bool { commandLifecycle.state.hasExited }
    var pendingShellInitialization: String?
    var isTerminalControlActive = false
    var isAlternateScreenActive: Bool { commandLifecycle.state.isAlternateScreenActive }
    var isApplicationCursorModeActive: Bool { commandLifecycle.state.isApplicationCursorModeActive }
    var mouseTrackingMode: Ansi.MouseTrackingMode?
    var usesSGRMouseMode = false
    var runningElapsedTimer: Timer?
    var commandHistory: [String] { commandLifecycle.state.commandHistory }
    var hostHistoryOptOutBlockIDs = Set<UUID>()
    var isFindMode = false
    var findCommandDraft = ""
    var findQuery = ""
    var findResults: [FindResult] = []
    var findResultIndex: Int?
    var isGitTreeVisible = false
    var canReplaceFreshSession = false
    var wasCreatedInThisController = true
    var createdAt: Date
    var commandCount: Int { commandLifecycle.state.commandCount }
    var lastCommandAt: Date? { commandLifecycle.state.lastCommandAt }

    init(
        title: String,
        delegate: NSTextViewDelegate,
        sessionRef: SessionRef = .local(UUID().uuidString),
        createdAt: Date = Date(),
        commandCount: Int = 0,
        lastCommandAt: Date? = nil,
        commandHistory: [String] = [],
        commandRunDates: [String: Date] = [:]
    ) {
        self.sessionRef = sessionRef
        self.session = PtySession(sessionRef: sessionRef)
        self.title = title
        self.createdAt = createdAt
        self.commandLifecycle = CommandLifecycle(
            cwd: FileManager.default.homeDirectoryForCurrentUser.path,
            commandCount: commandCount,
            lastCommandAt: lastCommandAt,
            commandHistory: commandHistory,
            commandRunDates: commandRunDates
        )
        super.init()
        buildView(delegate: delegate)
    }

    func setToolbarInset(_ inset: CGFloat) {
        scrollView.automaticallyAdjustsContentInsets = false
        // AppKit also applies content insets to the scroller; scrollerInsets would add them twice.
        scrollView.contentInsets.top = inset
        updateCommandBarInset()
    }

    func updateCommandBarInset() {
        let inset = commandBarView.isHidden ? 0 : max(0, sessionPickerView.frame.maxY - rootView.bounds.minY)
        commandBarMaterial.isHidden = commandBarView.isHidden
        let oldInset = scrollView.contentInsets.bottom
        let documentHeight = scrollView.documentView?.bounds.height ?? 0
        let wasAtBottom = scrollView.contentView.bounds.maxY >= documentHeight + oldInset - 1
        if oldInset != inset {
            scrollView.contentInsets.bottom = inset
            if wasAtBottom {
                scrollView.contentView.scroll(to: NSPoint(
                    x: 0,
                    y: max(-scrollView.contentInsets.top, documentHeight + inset - scrollView.contentView.bounds.height)
                ))
            }
        }
        // Insets reserve both overlays; short histories fill only the usable viewport.
        documentMinimumHeightConstraint.constant = -scrollView.contentInsets.top - inset
        updateScrollToBottomButton()
    }

    @objc private func updateScrollToBottomButton() {
        scrollToBottomButton.isHidden = isScrolledToBottom
    }

    @objc private func scrollToBottomClicked() {
        scrollToBottom(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    func scrollToBottom(animated: Bool = false) {
        guard let documentView = scrollView.documentView else { return }
        documentView.layoutSubtreeIfNeeded()
        scrollView.contentView.layoutSubtreeIfNeeded()
        let maxY = max(-scrollView.contentInsets.top, documentView.bounds.height + scrollView.contentInsets.bottom - scrollView.contentView.bounds.height)
        let destination = NSPoint(x: 0, y: maxY)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                scrollView.contentView.animator().setBoundsOrigin(destination)
            }
        } else {
            scrollView.contentView.scroll(to: destination)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateScrollToBottomButton()
    }

    private func buildView(delegate: NSTextViewDelegate) {
        rootView.translatesAutoresizingMaskIntoConstraints = false
        rootView.onLayout = { [weak self] in self?.updateCommandBarInset() }

        let documentView = FlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false

        stackView.orientation = .vertical
        stackView.spacing = 0
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        stackView.alignment = .leading
        stackView.distribution = .fill
        stackView.translatesAutoresizingMaskIntoConstraints = false

        documentView.addSubview(stackView)
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateScrollToBottomButton),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        documentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateScrollToBottomButton),
            name: NSView.frameDidChangeNotification, object: documentView
        )

        sessionPickerView.isHidden = true
        sessionPickerView.sessionPickerStack = sessionPickerStack
        sessionPickerView.commandInputView = inputView
        sessionPickerView.translatesAutoresizingMaskIntoConstraints = false

        sessionPickerStack.orientation = .vertical
        sessionPickerStack.spacing = 10
        sessionPickerStack.alignment = .leading
        sessionPickerStack.distribution = .fill
        sessionPickerStack.translatesAutoresizingMaskIntoConstraints = false
        sessionPickerView.addSubview(sessionPickerStack)

        inputView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        inputView.minSize = NSSize(width: 0, height: 44)
        inputView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        inputView.isVerticallyResizable = true
        inputView.delegate = delegate
        inputView.string = ""
        inputView.drawsBackground = false
        inputView.textColor = .labelColor
        inputView.insertionPointColor = .labelColor
        inputView.textContainerInset = NSSize(width: 12, height: 10)
        inputView.textContainer?.lineFragmentPadding = 0
        inputView.wantsLayer = true
        inputView.layer?.cornerRadius = 0
        inputView.layer?.borderWidth = 0
        configureCommandInputTextSystem(inputView)
        inputView.resetPlainTextAttributes()
        inputView.setAccessibilityLabel("Terminal command input")

        let inputScroll = NSScrollView()
        inputScroll.documentView = inputView
        inputScroll.hasVerticalScroller = true
        inputScroll.drawsBackground = false
        inputScroll.contentView.drawsBackground = false
        inputScroll.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .left
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLineStack.orientation = .horizontal
        statusLineStack.spacing = 6
        statusLineStack.alignment = .centerY
        statusLineStack.distribution = .fill
        statusLineStack.translatesAutoresizingMaskIntoConstraints = false
        statusLineStack.addArrangedSubview(statusLabel)

        commandBarView.wantsLayer = true
        commandBarMaterial.translatesAutoresizingMaskIntoConstraints = false
        commandBarView.translatesAutoresizingMaskIntoConstraints = false
        findCloseButton.isHidden = true
        findCloseButton.translatesAutoresizingMaskIntoConstraints = false
        scrollToBottomButton.isHidden = true
        scrollToBottomButton.translatesAutoresizingMaskIntoConstraints = false
        scrollToBottomButton.target = self
        scrollToBottomButton.action = #selector(scrollToBottomClicked)
        let buttons = NSStackView(views: [scrollToBottomButton, findCloseButton])
        buttons.orientation = .horizontal
        buttons.spacing = 0
        buttons.translatesAutoresizingMaskIntoConstraints = false
        completionPendingLine.wantsLayer = true
        completionPendingLine.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.75).cgColor
        completionPendingLine.isHidden = true
        completionPendingLine.translatesAutoresizingMaskIntoConstraints = false
        ptyPassthroughView.translatesAutoresizingMaskIntoConstraints = false
        ptyPassthroughView.isHidden = true
        ptyPassthroughView.onInput = { [weak self] sequence in
            self?.outputProcessor.prioritizeNextOutputForInput()
            self?.session.write(sequence)
        }
        ptyPassthroughView.usesApplicationCursorKeys = { [weak self] in
            self?.isApplicationCursorModeActive == true
        }
        commandBarView.addSubview(statusLineStack)
        commandBarView.addSubview(buttons)
        commandBarView.addSubview(inputScroll)
        commandBarView.addSubview(completionPendingLine)

        rootView.addSubview(scrollView)
        rootView.addSubview(commandBarMaterial)
        rootView.addSubview(sessionPickerView)
        rootView.addSubview(commandSeparator)
        rootView.addSubview(commandBarView)
        rootView.addSubview(ptyPassthroughView)

        sessionPickerHeightConstraint = sessionPickerView.heightAnchor.constraint(equalToConstant: 0)
        commandInputHeightConstraint = inputScroll.heightAnchor.constraint(
            equalToConstant: CommandInputTextView.minimumVisibleHeight
        )

        documentMinimumHeightConstraint = documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: rootView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            commandBarMaterial.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            commandBarMaterial.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            commandBarMaterial.topAnchor.constraint(equalTo: sessionPickerView.topAnchor),
            commandBarMaterial.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            sessionPickerView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            sessionPickerView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            sessionPickerView.bottomAnchor.constraint(equalTo: commandSeparator.topAnchor),
            sessionPickerHeightConstraint!,

            sessionPickerStack.leadingAnchor.constraint(equalTo: sessionPickerView.leadingAnchor, constant: 12),
            sessionPickerStack.trailingAnchor.constraint(
                equalTo: sessionPickerView.trailingAnchor,
                constant: -12
            ),
            sessionPickerStack.topAnchor.constraint(equalTo: sessionPickerView.topAnchor, constant: 8),
            sessionPickerStack.bottomAnchor.constraint(
                lessThanOrEqualTo: sessionPickerView.bottomAnchor,
                constant: -8
            ),

            commandSeparator.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            commandSeparator.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            commandSeparator.bottomAnchor.constraint(equalTo: commandBarView.topAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentMinimumHeightConstraint,

            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.topAnchor.constraint(greaterThanOrEqualTo: documentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),

            commandBarView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            commandBarView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            commandBarView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            statusLineStack.leadingAnchor.constraint(equalTo: commandBarView.leadingAnchor, constant: 12),
            statusLineStack.trailingAnchor.constraint(
                lessThanOrEqualTo: buttons.leadingAnchor,
                constant: -8
            ),
            statusLineStack.topAnchor.constraint(equalTo: commandBarView.topAnchor, constant: 8),
            buttons.heightAnchor.constraint(equalToConstant: 28),
            buttons.topAnchor.constraint(equalTo: commandBarView.topAnchor, constant: 4),
            buttons.trailingAnchor.constraint(equalTo: commandBarView.trailingAnchor, constant: -8),
            scrollToBottomButton.widthAnchor.constraint(equalToConstant: 28),
            scrollToBottomButton.heightAnchor.constraint(equalToConstant: 28),
            findCloseButton.widthAnchor.constraint(equalToConstant: 28),
            findCloseButton.heightAnchor.constraint(equalToConstant: 28),

            inputScroll.leadingAnchor.constraint(equalTo: commandBarView.leadingAnchor),
            inputScroll.trailingAnchor.constraint(equalTo: commandBarView.trailingAnchor),
            inputScroll.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 4),
            inputScroll.bottomAnchor.constraint(equalTo: commandBarView.bottomAnchor),
            commandInputHeightConstraint!,

            completionPendingLine.leadingAnchor.constraint(equalTo: commandBarView.leadingAnchor),
            completionPendingLine.trailingAnchor.constraint(equalTo: commandBarView.trailingAnchor),
            completionPendingLine.bottomAnchor.constraint(equalTo: commandBarView.bottomAnchor),
            completionPendingLine.heightAnchor.constraint(equalToConstant: 2),

            ptyPassthroughView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            ptyPassthroughView.topAnchor.constraint(equalTo: rootView.topAnchor),
            ptyPassthroughView.widthAnchor.constraint(equalToConstant: 0),
            ptyPassthroughView.heightAnchor.constraint(equalToConstant: 0)
        ])
    }

    private func configureCommandInputTextSystem(_ textView: NSTextView) {
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
    }
}

private enum GitTreeContent: Equatable {
    case graph([GitDirectoryStateProvider.TreeRow])
    case message(String)
}

private final class GitTreeCanvas: NSView {
    private struct ReferenceLabel: Equatable {
        let text: String
        let isActive: Bool
    }

    private let shaFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    private let referenceFont = NSFont.systemFont(ofSize: 9, weight: .medium)
    private let activeReferenceFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
    private let subjectFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    private let padding: CGFloat = 8
    private let rowHeight: CGFloat = 17
    private let graphCharacterWidth: CGFloat = 6
    private let labelSpacing: CGFloat = 5
    private let pillHeight: CGFloat = 13
    private let pillHorizontalPadding: CGFloat = 5
    private var content = GitTreeContent.message("")
    private var selectedHash: String?
    private(set) var preferredWidth: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(selectHash(_:))))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func display(_ content: GitTreeContent, minimumWidth: CGFloat) -> Bool {
        guard self.content != content else { return false }
        self.content = content
        if let selectedHash {
            let remainsVisible: Bool
            if case .graph(let rows) = content {
                remainsVisible = rows.contains(where: { $0.hash == selectedHash })
            } else {
                remainsVisible = false
            }
            if !remainsVisible {
                self.selectedHash = nil
            }
        }
        switch content {
        case .message(let message):
            setAccessibilityValue(message)
        case .graph(let rows):
            setAccessibilityValue(rows.compactMap(\.label).joined(separator: "\n"))
        }
        preferredWidth = measuredWidth(for: content)
        frame.size = NSSize(
            width: max(minimumWidth, preferredWidth),
            height: measuredHeight(for: content)
        )
        needsDisplay = true
        return true
    }

    func updateMinimumWidth(_ minimumWidth: CGFloat) {
        frame.size.width = max(minimumWidth, preferredWidth)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        switch content {
        case .message(let message):
            drawLabel(message, at: NSPoint(x: padding, y: padding))
        case .graph(let rows):
            for (index, row) in rows.enumerated() {
                let rowTop = padding + CGFloat(index) * rowHeight
                drawGraph(
                    row.graph,
                    previousGraph: index > 0 ? rows[index - 1].graph : nil,
                    nextGraph: rows.indices.contains(index + 1) ? rows[index + 1].graph : nil,
                    rowTop: rowTop
                )
                drawCommitLabel(row, at: index)
            }
        }
    }

    @objc private func selectHash(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        selectedHash = hash(at: recognizer.location(in: self))
        needsDisplay = true
        guard selectedHash != nil else { return }
        window?.makeFirstResponder(self)
    }

    @objc func copy(_ sender: Any?) {
        guard copySelection(to: .general) else {
            NSSound.beep()
            return
        }
    }

    private func drawGraph(
        _ graph: String,
        previousGraph: String?,
        nextGraph: String?,
        rowTop: CGFloat
    ) {
        let rowBottom = rowTop + rowHeight
        let midY = rowTop + rowHeight / 2
        let stroke = NSBezierPath()
        stroke.lineWidth = 1.3
        stroke.lineCapStyle = .round
        stroke.lineJoinStyle = .round

        for (index, character) in graph.enumerated() {
            let midX = laneX(index)
            switch character {
            case "|":
                stroke.move(to: NSPoint(x: midX, y: rowTop))
                stroke.line(to: NSPoint(x: midX, y: rowBottom))
            case "/", "\\":
                guard let lanes = Self.connectorLanes(for: character, at: index) else { continue }
                let start = NSPoint(x: laneX(lanes.top), y: rowTop)
                let end = NSPoint(x: laneX(lanes.bottom), y: rowBottom)
                stroke.move(to: start)
                stroke.curve(
                    to: end,
                    controlPoint1: NSPoint(x: start.x, y: midY),
                    controlPoint2: NSPoint(x: end.x, y: midY)
                )
            case "_", "-":
                guard index > 0 else { continue }
                stroke.move(to: NSPoint(x: laneX(index - 1), y: midY))
                stroke.line(to: NSPoint(x: laneX(index + 1), y: midY))
            case "*":
                if Self.graph(previousGraph, connects: index, atTop: false) {
                    stroke.move(to: NSPoint(x: midX, y: rowTop))
                    stroke.line(to: NSPoint(x: midX, y: midY))
                }
                if Self.graph(nextGraph, connects: index, atTop: true) {
                    stroke.move(to: NSPoint(x: midX, y: midY))
                    stroke.line(to: NSPoint(x: midX, y: rowBottom))
                }
            default:
                break
            }
        }

        NSColor.labelColor.withAlphaComponent(0.82).setStroke()
        stroke.stroke()

        for (index, character) in graph.enumerated() where character == "*" {
            let midX = padding + CGFloat(index) * graphCharacterWidth + graphCharacterWidth / 2
            let node = NSBezierPath(ovalIn: NSRect(x: midX - 3, y: midY - 3, width: 6, height: 6))
            NSColor.labelColor.setFill()
            node.fill()
        }
    }

    private static func graph(_ graph: String?, connects lane: Int, atTop: Bool) -> Bool {
        guard let graph else { return false }
        return graph.enumerated().contains { index, character in
            switch character {
            case "|", "*": return index == lane
            case "/": return (atTop ? index + 1 : index - 1) == lane
            case "\\": return (atTop ? index - 1 : index + 1) == lane
            default: return false
            }
        }
    }

    private func laneX(_ index: Int) -> CGFloat {
        padding + CGFloat(index) * graphCharacterWidth + graphCharacterWidth / 2
    }

    private static func connectorLanes(
        for character: Character,
        at index: Int
    ) -> (top: Int, bottom: Int)? {
        guard index > 0 else { return nil }
        switch character {
        case "/": return (index + 1, index - 1)
        case "\\": return (index - 1, index + 1)
        default: return nil
        }
    }

    static func connectorRoutingSelfTest() -> Bool {
        guard let fork = connectorLanes(for: "\\", at: 1),
              let merge = connectorLanes(for: "/", at: 3) else { return false }
        return fork == (top: 0, bottom: 2)
            && merge == (top: 4, bottom: 2)
            && connectorLanes(for: "\\", at: 0) == nil
            && graph("|\\", connects: 0, atTop: true)
            && graph("|\\", connects: 2, atTop: false)
            && !graph("|\\", connects: 2, atTop: true)
            && !graph(nil, connects: 0, atTop: false)
    }

    static func referenceLabelSelfTest() -> Bool {
        referenceLabels("HEAD -> main, origin/main, tag: 4.0.1, branch: feature")
            == [
                ReferenceLabel(text: "main", isActive: true),
                ReferenceLabel(text: "origin/main", isActive: false),
                ReferenceLabel(text: "4.0.1", isActive: false),
                ReferenceLabel(text: "feature", isActive: false)
            ]
    }

    static func hashSelectionSelfTest() -> Bool {
        let view = GitTreeCanvas(frame: .zero)
        let row = GitDirectoryStateProvider.TreeRow(
            graph: "* ",
            hash: "abc1234",
            decorations: "",
            subject: "Commit"
        )
        view.content = .graph([row])
        guard let rect = view.hashRect(for: row, at: 0),
              view.hash(at: NSPoint(x: rect.midX, y: rect.midY)) == "abc1234",
              view.hash(at: NSPoint(x: rect.maxX + 1, y: rect.midY)) == nil,
              view.responds(to: #selector(NSText.copy(_:)))
        else { return false }

        view.selectedHash = "abc1234"
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("GitTreeCanvasSelectionSelfTest"))
        return view.copySelection(to: pasteboard)
            && pasteboard.string(forType: .string) == "abc1234"
    }

    private func drawLabel(_ label: String, at point: NSPoint) {
        (label as NSString).draw(at: point, withAttributes: [
            .font: subjectFont,
            .foregroundColor: NSColor.labelColor
        ])
    }

    private func drawCommitLabel(
        _ row: GitDirectoryStateProvider.TreeRow,
        at index: Int
    ) {
        guard let hash = row.hash,
              let hashRect = hashRect(for: row, at: index)
        else { return }
        let point = NSPoint(x: hashRect.minX + 2, y: hashRect.minY)
        var x = point.x
        if selectedHash == hash {
            NSColor.selectedTextBackgroundColor.setFill()
            NSBezierPath(roundedRect: hashRect, xRadius: 2, yRadius: 2).fill()
        }
        drawText(
            hash,
            font: shaFont,
            at: NSPoint(x: x, y: point.y + 1),
            color: selectedHash == hash ? .selectedTextColor : .labelColor
        )
        x += textWidth(hash, font: shaFont)

        for reference in Self.referenceLabels(row.decorations) {
            x += labelSpacing
            let width = pillWidth(reference)
            let rect = NSRect(x: x, y: point.y, width: width, height: pillHeight)
            (reference.isActive
                ? NSColor.controlAccentColor
                : NSColor.labelColor.withAlphaComponent(0.14)
            ).setFill()
            NSBezierPath(
                roundedRect: rect,
                xRadius: pillHeight / 2,
                yRadius: pillHeight / 2
            ).fill()
            drawText(
                reference.text,
                font: reference.isActive ? activeReferenceFont : referenceFont,
                at: NSPoint(x: rect.minX + pillHorizontalPadding, y: rect.minY + 1),
                color: reference.isActive ? .selectedControlTextColor : .labelColor
            )
            x = rect.maxX
        }

        guard !row.subject.isEmpty else { return }
        x += labelSpacing
        drawText(row.subject, font: subjectFont, at: NSPoint(x: x, y: point.y))
    }

    private static func referenceLabels(_ decorations: String) -> [ReferenceLabel] {
        decorations.split(separator: ",").map { decoration in
            let label = decoration.trimmingCharacters(in: .whitespaces)
            let isActive = label.hasPrefix("HEAD -> ")
            for prefix in ["tag: ", "branch: ", "HEAD -> "] where label.hasPrefix(prefix) {
                return ReferenceLabel(
                    text: String(label.dropFirst(prefix.count)),
                    isActive: isActive
                )
            }
            return ReferenceLabel(text: label, isActive: isActive)
        }
    }

    private func drawText(
        _ text: String,
        font: NSFont,
        at point: NSPoint,
        color: NSColor = .labelColor
    ) {
        (text as NSString).draw(at: point, withAttributes: [
            .font: font,
            .foregroundColor: color
        ])
    }

    private func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private func hashRect(
        for row: GitDirectoryStateProvider.TreeRow,
        at index: Int
    ) -> NSRect? {
        guard let hash = row.hash else { return nil }
        let x = padding + CGFloat(row.graph.count) * graphCharacterWidth + 4
        let y = padding + CGFloat(index) * rowHeight + 2
        return NSRect(
            x: x,
            y: y,
            width: ceil(textWidth(hash, font: shaFont)) + 4,
            height: pillHeight
        )
    }

    private func hash(at point: NSPoint) -> String? {
        guard case .graph(let rows) = content else { return nil }
        return rows.enumerated().first { index, row in
            hashRect(for: row, at: index)?.contains(point) == true
        }?.element.hash
    }

    @discardableResult
    private func copySelection(to pasteboard: NSPasteboard) -> Bool {
        guard let selectedHash else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(selectedHash, forType: .string)
    }

    private func pillWidth(_ reference: ReferenceLabel) -> CGFloat {
        let font = reference.isActive ? activeReferenceFont : referenceFont
        return ceil(textWidth(reference.text, font: font)) + pillHorizontalPadding * 2
    }

    private func commitLabelWidth(for row: GitDirectoryStateProvider.TreeRow) -> CGFloat {
        guard let hash = row.hash else { return 0 }
        var width = textWidth(hash, font: shaFont)
        for reference in Self.referenceLabels(row.decorations) {
            width += labelSpacing + pillWidth(reference)
        }
        if !row.subject.isEmpty {
            width += labelSpacing + textWidth(row.subject, font: subjectFont)
        }
        return width
    }

    private func measuredWidth(for content: GitTreeContent) -> CGFloat {
        switch content {
        case .message(let message):
            return padding * 2 + textWidth(message, font: subjectFont)
        case .graph(let rows):
            return rows.reduce(padding * 2) { width, row in
                let graphWidth = CGFloat(row.graph.count) * graphCharacterWidth
                let labelWidth = row.hash == nil ? 0 : commitLabelWidth(for: row) + 6
                return max(width, padding * 2 + graphWidth + labelWidth)
            }
        }
    }

    private func measuredHeight(for content: GitTreeContent) -> CGFloat {
        switch content {
        case .message:
            return padding * 2 + rowHeight
        case .graph(let rows):
            return padding * 2 + CGFloat(max(1, rows.count)) * rowHeight
        }
    }
}

private final class GitTreeView: NSView {
    private let canvas = GitTreeCanvas(frame: .zero)
    private let scrollView = NSScrollView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = TahoeGlassPalette.commandBackground.cgColor

        canvas.setAccessibilityRole(.staticText)
        canvas.setAccessibilityLabel("Git tree")
        scrollView.documentView = canvas
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let separator = SeparatorView()

        addSubview(scrollView)
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            scrollView.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = TahoeGlassPalette.commandBackground.cgColor
        }
        canvas.needsDisplay = true
    }

    override func layout() {
        super.layout()
        canvas.updateMinimumWidth(scrollView.contentSize.width)
    }

    func display(_ content: GitTreeContent) {
        guard canvas.display(content, minimumWidth: scrollView.contentSize.width) else { return }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

final class TerminalViewController: NSViewController, NSTextViewDelegate {
    private typealias StoredTab = SessionCatalog.Record

    private struct InitialCommand {
        let command: String
        let exitsShellAfterCompletion: Bool
    }

    private struct TerminalGridSize {
        let rows: UInt16
        let cols: UInt16
    }

    let standalone: Bool
    private let restoredSession: SessionCatalog.Record?
    private let initialHostID: String?
    private let initialDirectory: URL
    private let selfTestCommand: String?
    private let skipsSessionPicker: Bool
    private let launchCommand: String?
    private let sessionHosts: [TerminalHost]
    private let sessionCatalog: SessionCatalog
    private var windowID: String { sessionCatalog.windowID }
    private let restoresPersistedWindow: Bool
    private var didRunSelfTest = false
    private var initialCommands: [UUID: InitialCommand] = [:]
    private var tabs: [TerminalTab] = []
    private var closedTabs: [StoredTab] { sessionCatalog.closedTabs }
    private var isKillingClosedTabs = false
    private var killingSessionRefs = Set<SessionRef>()
    private var activeTabID: UUID?
    private var sessionPickerCandidatesByTab: [UUID: [SessionRef: SessionPickerCandidate]] = [:]
    private var sessionPickerModelsByTab: [UUID: SessionPickerModel] = [:]
    private let sessionPickerInventory = SessionPickerModel.Inventory()
    var backgroundBlurEffect = BackgroundBlurEffect.preferred {
        didSet {
            guard isViewLoaded else { return }
            (view as? TahoeGlassRootView)?.backgroundBlurEffect = backgroundBlurEffect
        }
    }

    private let contentContainer = NSView()
    private let gitTreeView = GitTreeView(frame: .zero)
    private let resizeTooltipView = ResizeMetricsTooltipView()
    private let completionEngine = PortalCompletionEngine()
    private let completionQueue = DispatchQueue(label: "dev.mxcl.portal.completion", qos: .userInitiated)
    private let gitStateProvider = GitDirectoryStateProvider()
    private let gitStateQueue = DispatchQueue(label: "dev.mxcl.portal.git-state", qos: .utility)
    private let sessionCleanupQueue = DispatchQueue(label: "dev.mxcl.portal.session-cleanup", qos: .utility)
    private let completionPopup = CompletionPopupController()
    private var completionRequestSerial = 0
    private var completionCancellation: CompletionCancellation?
    private var pendingCompletionRequestTabID: UUID?
    private var deferredCompletionAcceptanceSerial: Int?
    private var activeCompletionRange: NSRange?
    private var activeCompletionCommonPrefix: String?
    private var activeCompletionMode: CompletionRequestMode?
    private var canInsertCommandSeparator = false
    private var isApplyingCompletion = false
    private var isShowingResizeTooltip = false
    private var sessionPickerMouseDownMonitor: Any?
    private var commandFocusMonitor: Any?
    private var contentTrailingConstraint: NSLayoutConstraint?
    private var contentTrailingToGitTreeConstraint: NSLayoutConstraint?
    private var isGitTreeVisible: Bool { activeTab?.isGitTreeVisible == true }
    private var isGitTreeRefreshPending = false
    private var gitRepositoryWatcher: RepositoryWatcher?
    private var gitRepositoryWatchURL: URL?
    private var gitRepositoryWatchTask: Task<Void, Never>?
    private var gitTreeRefreshAgain = false
    private let blockViewRenderDelay: TimeInterval = 1.0 / 12.0
    private let interactiveBlockViewRenderDelay: TimeInterval = 1.0 / 60.0
    private let fallbackDisplayRefreshRate = 60
    private static let didRunPassthroughRoutingSelfTest: Void = {
        assert(PtyPassthroughView.passthroughRoutingSelfTest())
        assert(TerminalViewController.shouldSendInputToPty(
            isFindMode: false,
            isTerminalControlActive: false,
            isCommandRunning: true
        ))
        assert(TerminalViewController.shouldSendInputToPty(
            isFindMode: false,
            isTerminalControlActive: true,
            isCommandRunning: true
        ))
        assert(TerminalMouseEncoder.selfTest())
        assert(TerminalOutputProcessor.alternateScreenTranscriptSelfTest())
        assert(TerminalOutputProcessor.terminalSizeProbeSelfTest())
        assert(TerminalOutputProcessor.terminalResponsesAreImmediateSelfTest())
        assert(TerminalOutputProcessor.inputFeedbackPrioritySelfTest())
        assert(TerminalOutputProcessor.truncatedHistoryReplaySelfTest())
        assert(Ansi.terminalScreenScrollRegionSelfTest())
        assert(Ansi.terminalScreenFixedHeightSelfTest())
        assert(Ansi.terminalScreenDeferredWrapSelfTest())
        assert(SessionPickerView.interactiveControlHitTestingSelfTest())
        assert(SessionPickerView.keyboardNavigationSelfTest())
        assert(CompletionPopupController.selectionSelfTest())
        assert(CommandInputTextView.completionPreviewPreservesCaretSelfTest())
        assert(CommandInputTextView.expandingHeightSelfTest())
        assert(CommandInputTextView.multilinePasteSelfTest())
        assert(TerminalViewController.historyCompletionReplacementRangeSelfTest())
        assert(PortalCompletionEngine.historyMergePrefixSelfTest())
        assert(PortalCompletionEngine.applicationCompletionSelfTest())
        assert(PortalCompletionEngine.applicationRefreshSelfTest())
        assert(PortalCompletionEngine.calculatorCompletionSelfTest())
        assert(ShellCompletionParser.midTokenReplacementRangeSelfTest())
        assert(GitDirectoryStateProvider.treeParsingSelfTest())
        assert(GitTreeCanvas.connectorRoutingSelfTest())
        assert(GitTreeCanvas.referenceLabelSelfTest())
        assert(GitTreeCanvas.hashSelectionSelfTest())
        assert(gitTreeContent(nil, location: .local) == .message("Not a Git repository"))
        assert(gitTreeContent([], location: .local) == .message("No commits yet"))
        assert(gitTreeContent(nil, location: .sshHost("mac")) == .message("Git tree is unavailable for remote tabs"))
        let shellEnvironment = inheritedShellEnvironment([
            "PAGER": "cat",
            "GIT_PAGER": "cat",
            "PRESERVED": "yes",
        ])
        assert(shellEnvironment["PAGER"] == "less")
        assert(shellEnvironment["GIT_PAGER"] == "less")
        assert(shellEnvironment["PRESERVED"] == "yes")
        assert(inheritedShellEnvironment(["PAGER": "less"])["PAGER"] == "less")
        assert(inheritedShellEnvironment([:])["GIT_PAGER"] == "less")
    }()

    init(
        selfTestCommand: String? = nil,
        windowID: String = UUID().uuidString,
        restoresPersistedWindow: Bool = true,
        initialDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        initialHostID: String? = nil,
        standalone: Bool = false,
        skipsSessionPicker: Bool = false,
        launchCommand: String? = nil,
        sessionHosts: [TerminalHost] = [],
        restoredSession: SessionCatalog.Record? = nil,
        sessionCatalog: SessionCatalog? = nil
    ) {
        _ = Self.didRunPassthroughRoutingSelfTest
        self.restoredSession = restoredSession
        self.standalone = standalone
        self.skipsSessionPicker = skipsSessionPicker
        self.initialHostID = initialHostID
        self.initialDirectory = initialDirectory
        self.selfTestCommand = selfTestCommand
        self.launchCommand = launchCommand
        self.sessionHosts = sessionHosts
        self.sessionCatalog = sessionCatalog ?? SessionCatalog(url: Self.sessionStateURL().deletingLastPathComponent()
            .appendingPathComponent((standalone ? "windows/" : "projects/") + windowID + ".json"), windowID: windowID)
        self.restoresPersistedWindow = restoresPersistedWindow
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        _ = Self.didRunPassthroughRoutingSelfTest
        self.restoredSession = nil
        self.standalone = false
        self.skipsSessionPicker = false
        self.initialHostID = nil
        self.initialDirectory = FileManager.default.homeDirectoryForCurrentUser
        self.selfTestCommand = nil
        self.launchCommand = nil
        self.sessionHosts = []
        self.sessionCatalog = SessionCatalog(url: Self.sessionStateURL(), windowID: UUID().uuidString)
        self.restoresPersistedWindow = true
        super.init(coder: coder)
    }

    private let trafficLightBorderView = TrafficLightBorderView()

    var toolbarInset: CGFloat = 0 {
        didSet {
            guard toolbarInset != oldValue, isViewLoaded else { return }
            handleRootLayout()
        }
    }

    override func loadView() {
        let rootView = TahoeGlassRootView()
        rootView.usesPortalMaterials = standalone
        rootView.backgroundBlurEffect = backgroundBlurEffect
        rootView.onAppearanceChange = { [weak self] in
            guard let self else { return }
            for tab in tabs {
                tab.commandBarView.layer?.backgroundColor = nil
                updateCommandBarDirectoryStatus(for: tab, forceRefresh: true)
                tab.inputView.resetPlainTextAttributes()
            }
        }
        rootView.onLayout = { [weak self] in
            self?.handleRootLayout()
        }

        view = rootView

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        gitTreeView.isHidden = true
        resizeTooltipView.isHidden = true

        view.addSubview(contentContainer)
        view.addSubview(gitTreeView)
        view.addSubview(resizeTooltipView)
        if standalone {
            trafficLightBorderView.material = .hudWindow
            trafficLightBorderView.blendingMode = .withinWindow
            trafficLightBorderView.state = .active
            trafficLightBorderView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(trafficLightBorderView)
            NSLayoutConstraint.activate([
                trafficLightBorderView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                trafficLightBorderView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                trafficLightBorderView.topAnchor.constraint(equalTo: view.topAnchor),
                trafficLightBorderView.heightAnchor.constraint(equalToConstant: 50)
            ])
        }


        let contentTopConstraint = contentContainer.topAnchor.constraint(
            equalTo: view.topAnchor,
            constant: 0
        )

        let contentTrailingConstraint = contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        let contentTrailingToGitTreeConstraint = contentContainer.trailingAnchor.constraint(
            equalTo: gitTreeView.leadingAnchor
        )
        self.contentTrailingConstraint = contentTrailingConstraint
        self.contentTrailingToGitTreeConstraint = contentTrailingToGitTreeConstraint

        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(
                equalTo: view.leadingAnchor
            ),
            contentTrailingConstraint,
            contentTopConstraint,
            contentContainer.bottomAnchor.constraint(
                equalTo: view.bottomAnchor
            ),

            gitTreeView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            gitTreeView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            gitTreeView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            gitTreeView.widthAnchor.constraint(equalToConstant: 300)
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        completionPopup.onExternalDismiss = { [weak self] in
            self?.dismissCompletion()
        }
        completionPopup.onSelectionChanged = { [weak self] suggestion in
            self?.previewCompletionSelection(suggestion)
        }
        completionPopup.onAcceptSuggestion = { [weak self] suggestion in
            self?.acceptCompletionSelection(suggestion)
        }
        restoreSessionState()
        installSessionPickerMouseDownMonitor()
        installCommandFocusMonitor()
    }

    deinit {
        if let sessionPickerMouseDownMonitor {
            NSEvent.removeMonitor(sessionPickerMouseDownMonitor)
        }
        if let commandFocusMonitor {
            NSEvent.removeMonitor(commandFocusMonitor)
        }
        gitRepositoryWatchTask?.cancel()
        stopAllSessions()
    }

    var paletteHistory: [SessionCatalog.Record] {
        isViewLoaded ? tabs.filter { !$0.hasExited }.map { storedTab(from: $0) }
            : sessionCatalog.visibleRecords()
    }

    func paletteCommandIsConnecting(_ sessionRef: SessionRef) -> Bool {
        guard let tab = tabs.first(where: { $0.sessionRef == sessionRef }), !tab.hasExited else { return false }
        return tab.isReplayingHistory || (!tab.isShellReady && !isCommandRunning(in: tab))
    }

    @discardableResult
    func prefillPaletteCommand(_ command: String, sessionRef: SessionRef) -> Bool {
        guard let tab = tabs.first(where: { $0.sessionRef == sessionRef }),
              tab.isShellReady, !tab.hasExited, !tab.isReplayingHistory,
              !tab.isTerminalControlActive, !isCommandRunning(in: tab) else { return false }
        dismissCompletion()
        hideSessionPicker(for: tab)
        exitFindMode(in: tab)
        activateTab(tab.id)
        tab.commandLifecycle.apply(.resetHistorySelection)
        setInput(command, in: tab)
        focusInput(for: tab)
        return true
    }

    @discardableResult
    func insertReference(_ reference: String) -> Bool {
        guard let tab = activeTab, tab.isShellReady, !tab.hasExited, !tab.isReplayingHistory,
              !tab.isTerminalControlActive, !isCommandRunning(in: tab) else { return false }
        dismissCompletion()
        hideSessionPicker(for: tab)
        exitFindMode(in: tab)
        tab.commandLifecycle.apply(.resetHistorySelection)
        tab.inputView.insertText(reference, replacementRange: tab.inputView.selectedRange())
        tab.inputView.normalizePlainTextStorage()
        focusInput(for: tab)
        return true
    }

    static func referenceInsertionSelfTest() -> Bool {
        let controller = TerminalViewController(restoresPersistedWindow: false)
        controller.loadView()
        let tab = TerminalTab(title: "test", delegate: controller)
        controller.tabs = [tab]
        controller.activeTabID = tab.id
        guard !controller.insertReference("main") else { return false }
        tab.commandLifecycle.apply(.shellReady(cwd: "/tmp"))
        tab.inputView.string = "git diff old -- file"
        tab.inputView.setSelectedRange(NSRange(location: 9, length: 3))
        guard controller.insertReference("main"), tab.inputView.string == "git diff main -- file",
              tab.inputView.selectedRange().location == 13, tab.commandCount == 0 else { return false }
        tab.commandLifecycle.apply(.submit(command: "sleep 10", cwd: "/tmp", at: Date()))
        guard !controller.insertReference("abc123"), tab.inputView.string == "git diff main -- file" else { return false }
        tab.commandLifecycle.apply(.commandFinished(status: 0, isReplay: false, at: Date()))
        tab.commandLifecycle.apply(.beginHistoryReplay)
        guard !controller.insertReference("main") else { return false }
        tab.commandLifecycle.apply(.finishHistoryReplay)
        tab.commandLifecycle.apply(.shellExited(status: 0, at: Date()))
        return !controller.insertReference("main")
    }

    var onActivityChange: (() -> Void)?
    var onOutputActivity: (() -> Void)?

    var projectTerminalState: TerminalWorkspace.TerminalState? {
        let liveTabs = tabs.filter { !$0.hasExited }
        guard !liveTabs.isEmpty else { return nil }
        return liveTabs.contains(where: { isCommandRunning(in: $0) }) ? .active : .waiting
    }
    private var isTerminalVisible = false

    var projectActivity: TerminalWorkspace.Activity? {
        if tabs.contains(where: { isCommandRunning(in: $0) }) { return .running }
        return tabs.contains(where: { $0.hasUnviewedCompletion }) ? .unviewed : nil
    }

    private func markActiveTerminalViewed() {
        if isTerminalVisible && view.window?.isKeyWindow == true {
            activeTab?.hasUnviewedCompletion = false
        }
        onActivityChange?()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        isTerminalVisible = true
        markActiveTerminalViewed()
        if tabs.isEmpty { createTab() }
        windowDidAttach()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        isTerminalVisible = false
        discardUntouchedSessions()
    }

    func discardUntouchedSessions(except retainedID: UUID? = nil) {
        for tab in tabs where tab.id != retainedID && tab.wasCreatedInThisController && tab.commandCount == 0
            && tab.pendingBlockID == nil && tab.activeBlockID == nil
            && initialCommands[tab.id] == nil && tab.inputView.string.isEmpty
            && !isSessionVisibleOutsideTab(tab) {
            closeTab(withID: tab.id, createsReplacement: false)
        }
    }

    static func externalBranchChangeSelfTest(
        directory: URL, standalone: Bool, switchBranch: () throws -> Void
    ) async throws -> Bool {
        let catalog = SessionCatalog(url: directory.appendingPathComponent("sessions.json"), windowID: "test")
        let controller = TerminalViewController(restoresPersistedWindow: false,
            standalone: standalone, sessionCatalog: catalog)
        controller.loadView()
        let tab = TerminalTab(title: "test", delegate: controller)
        tab.commandLifecycle.apply(.shellReady(cwd: directory.path))
        controller.tabs = [tab]
        controller.activeTabID = tab.id
        defer {
            controller.gitRepositoryWatchTask?.cancel()
            controller.gitRepositoryWatcher = nil
            tab.session.stop()
        }
        controller.refreshVisibleCommandBarGitStatus()
        controller.refreshGitTreeIfVisible()
        await controller.gitRepositoryWatchTask?.value
        for _ in 0..<100 {
            if tab.statusLabel.stringValue.contains("git before") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard tab.statusLabel.stringValue.contains("git before"), !controller.isGitTreeVisible else {
            return false
        }
        try switchBranch()
        for _ in 0..<150 {
            if tab.statusLabel.stringValue.contains("git after") { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    static func outputScrollingSelfTest(startsAtBottom: Bool) async -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = SessionCatalog(url: directory.appendingPathComponent("sessions.json"), windowID: "test")
        let controller = TerminalViewController(restoresPersistedWindow: false, sessionCatalog: catalog)
        let tab = TerminalTab(title: "Test", delegate: controller)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        host.addSubview(tab.rootView)
        NSLayoutConstraint.activate([
            tab.rootView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            tab.rootView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            tab.rootView.topAnchor.constraint(equalTo: host.topAnchor),
            tab.rootView.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        tab.setToolbarInset(38)
        tab.commandLifecycle.apply(.shellReady(cwd: "/tmp"))
        let change = tab.commandLifecycle.apply(.submit(command: "test", cwd: "/tmp", at: Date()))
        guard let id = change.addedBlockIDs.first else { return false }
        tab.commandLifecycle.apply(.commandStarted)
        func render(lines: Int) {
            let output = String(repeating: "output line\n", count: lines)
            tab.commandLifecycle.apply(.output(blockID: id, plainText: output,
                attributedText: NSAttributedString(string: output),
                isAlternateScreenActive: false, isApplicationCursorModeActive: false))
            controller.updateBlockViewNow(for: id, in: tab)
            host.layoutSubtreeIfNeeded()
        }
        func drainScroll() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        render(lines: 100)
        await drainScroll()
        controller.scrollToBottomNow(tab)
        if !startsAtBottom {
            tab.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 100))
        }
        let originalY = tab.scrollView.contentView.bounds.minY
        render(lines: 150)
        await drainScroll()
        func positionIsCorrect() -> Bool {
            let documentHeight = tab.scrollView.documentView!.bounds.height
            guard documentHeight > tab.scrollView.contentView.bounds.height else { return false }
            if startsAtBottom {
                return abs(tab.scrollView.contentView.bounds.maxY
                    - documentHeight - tab.scrollView.contentInsets.bottom) < 1
            }
            return abs(tab.scrollView.contentView.bounds.minY - originalY) < 1
        }
        guard positionIsCorrect() else { return false }
        controller.handleMarker(PortalMarker(rawValue: "D;1"), isReplay: false, in: tab)
        await drainScroll()
        guard positionIsCorrect() else { return false }
        tab.commandLifecycle.apply(.submit(command: "next", cwd: "/tmp", at: Date()))
        guard let block = tab.blocks.last else { return false }
        controller.addBlockView(block, to: tab)
        host.layoutSubtreeIfNeeded()
        await drainScroll()
        return positionIsCorrect()
    }

    static func sessionStartupStatusesSelfTest() -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = SessionCatalog(url: directory.appendingPathComponent("sessions.json"), windowID: "test")
        // An unconfigured host exercises the UI paths without launching a shell.
        let hostID = UUID().uuidString
        let controller = TerminalViewController(restoresPersistedWindow: false,
            initialHostID: hostID, sessionCatalog: catalog)
        controller.loadView()
        defer { controller.tabs.forEach { $0.session.stop() } }
        controller.createTab(activates: false, persists: false)
        guard let fresh = controller.tabs.last else { return [] }
        var statuses = [fresh.statusLabel.stringValue]
        let ref = SessionRef(location: .sshHost(hostID), sessionID: UUID().uuidString)
        controller.createTab(from: StoredTab(sessionRef: ref, sessionID: ref.sessionID,
            title: "Saved", cwd: directory.path, commandCount: 1), activates: false, persists: false)
        guard let restored = controller.tabs.last else { return [] }
        statuses.append(restored.statusLabel.stringValue)
        // A saved session may have disappeared; the daemon can create a replacement.
        restored.session.onReady?(true)
        statuses.append(restored.statusLabel.stringValue)
        for action in [SessionPickerCandidate.Action.create, .attach] {
            controller.attachSessionFromPicker(SessionPickerCandidate(
                sessionRef: ref, hostTitle: "Test", title: "Session", cwd: directory.path,
                isClosed: false, commandCount: 0, commandHistory: [], action: action), in: fresh)
            statuses.append(fresh.statusLabel.stringValue)
        }
        return statuses
    }

    static func paletteCommandPrefillSelfTest() -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = SessionCatalog(url: directory.appendingPathComponent("sessions.json"), windowID: "test")
        let saved = SessionCatalog.Record(sessionRef: .local("saved"), sessionID: "saved", title: "deploy",
            cwd: "/tmp", commandCount: 1, commandHistory: ["./scripts/deploy"])
        do { try catalog.persist(visibleTabs: [saved], activeSessionRef: saved.resolvedRef) }
        catch { return false }
        let controller = TerminalViewController(sessionCatalog: catalog)
        guard controller.paletteHistory.first?.commandHistory == ["./scripts/deploy"],
              !controller.isViewLoaded else { return false }
        controller.loadView()
        let first = TerminalTab(title: "first", delegate: controller)
        let target = TerminalTab(title: "target", delegate: controller, commandHistory: ["./scripts/deploy here"])
        controller.tabs = [first, target]
        controller.activeTabID = first.id
        target.commandLifecycle.apply(.shellReady(cwd: "/tmp"))
        let command = "./scripts/deploy here\necho done"
        guard controller.prefillPaletteCommand(command, sessionRef: target.sessionRef),
              controller.activeTabID == target.id, target.inputView.string == command,
              target.commandCount == 0, target.blocks.isEmpty else { return false }
        target.commandLifecycle.apply(.submit(command: "sleep 10", cwd: "/tmp", at: Date()))
        controller.activeTabID = first.id
        guard !controller.prefillPaletteCommand("must not run", sessionRef: target.sessionRef),
              controller.activeTabID == first.id, target.inputView.string == command,
              target.commandCount == 1 else { return false }
        target.commandLifecycle.apply(.commandFinished(status: 0, isReplay: false, at: Date()))
        target.commandLifecycle.apply(.beginHistoryReplay)
        guard !controller.prefillPaletteCommand("must not run", sessionRef: target.sessionRef) else { return false }
        target.commandLifecycle.apply(.finishHistoryReplay)
        target.commandLifecycle.apply(.shellExited(status: 0, at: Date()))
        return !controller.prefillPaletteCommand("must not run", sessionRef: target.sessionRef)
            && !controller.prefillPaletteCommand("must not run", sessionRef: .local("missing"))
    }

    static func projectActivitySelfTest() -> Bool {
        let controller = TerminalViewController(restoresPersistedWindow: false)
        controller.loadView()
        let finished = TerminalTab(title: "finished", delegate: controller)
        let running = TerminalTab(title: "running", delegate: controller)
        controller.tabs = [finished, running]
        guard controller.projectActivity == nil, controller.projectTerminalState == .waiting else { return false }
        finished.hasUnviewedCompletion = true
        guard controller.projectActivity == .unviewed else { return false }
        running.commandLifecycle.apply(.submit(command: "sleep 1", cwd: "/tmp", at: Date()))
        guard controller.projectActivity == .running, controller.projectTerminalState == .active else { return false }
        running.commandLifecycle.apply(.commandFinished(status: 0, isReplay: false, at: Date()))
        guard controller.projectActivity == .unviewed else { return false }
        controller.activeTabID = finished.id
        controller.markActiveTerminalViewed()
        guard controller.projectActivity == .unviewed else { return false }
        final class ViewedWindow: NSWindow { override var isKeyWindow: Bool { true } }
        let window = ViewedWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView()
        window.contentView?.addSubview(controller.view)
        defer { window.close() }
        controller.isTerminalVisible = true
        controller.markActiveTerminalViewed()
        guard controller.projectActivity == nil, controller.projectTerminalState == .waiting else { return false }
        finished.commandLifecycle.apply(.shellExited(status: 0, at: Date()))
        running.commandLifecycle.apply(.shellExited(status: 0, at: Date()))
        return controller.projectTerminalState == nil
    }

    static func untouchedSessionCleanupSelfTest() -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = SessionCatalog(url: directory.appendingPathComponent("sessions.json"), windowID: "test")
        let controller = TerminalViewController(sessionCatalog: catalog)
        controller.loadView()
        let empty = TerminalTab(title: "empty", delegate: controller)
        let used = TerminalTab(title: "used", delegate: controller, commandCount: 1)
        let draft = TerminalTab(title: "draft", delegate: controller)
        draft.inputView.string = "echo unfinished"
        let attached = TerminalTab(title: "attached", delegate: controller)
        attached.wasCreatedInThisController = false
        controller.tabs = [empty, used, draft, attached]
        for tab in controller.tabs {
            controller.installTabView(tab)
        }
        controller.activeTabID = draft.id
        let window = StandaloneTerminalWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = window
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        // Losing focus must preserve the open shell, including before its first command.
        window.delegate?.windowDidResignKey?(Notification(name: NSWindow.didResignKeyNotification, object: window))
        guard controller.tabs.count == 4 else { return false }
        controller.discardUntouchedSessions(except: empty.id)
        guard controller.tabs.count == 4 else { return false }
        controller.discardUntouchedSessions()
        guard controller.tabs.map(\.id) == [used.id, draft.id, attached.id] else { return false }
        // Leaving the final untouched terminal must not immediately spawn a replacement.
        used.session.stop()
        draft.session.stop()
        attached.session.stop()
        controller.tabs = [empty]
        controller.activeTabID = empty.id
        controller.discardUntouchedSessions()
        return controller.tabs.isEmpty && controller.activeTabID == nil && catalog.closedTabs.isEmpty
    }

    func windowDidAttach() {
        if let tab = activeTab {
            focusInput(for: tab)
        }
    }

    func windowDidBecomeActive() {
        if standalone, let tab = activeTab { view.window?.title = tab.title }
        markActiveTerminalViewed()
        if isViewLoaded && tabs.isEmpty { createTab() }
        restoreCommandFocusIfNeeded()
        refreshVisibleCommandBarGitStatus()
        refreshGitTreeIfVisible()
    }

    func toggleGitTree(_ sender: Any?) {
        guard let tab = activeTab else { return }
        tab.isGitTreeVisible.toggle()
        applyGitTreeVisibility(for: tab)
        focusInput(for: tab)
    }

    private func applyGitTreeVisibility(for tab: TerminalTab) {
        guard tab.id == activeTabID else { return }
        let isVisible = tab.isGitTreeVisible
        contentTrailingConstraint?.isActive = !isVisible
        contentTrailingToGitTreeConstraint?.isActive = isVisible
        gitTreeView.isHidden = !isVisible
        if isVisible {
            gitTreeView.display(.message("Loading Git tree…"))
        }
        refreshGitTreeIfVisible()
        tab.blockViews.values.forEach { $0.needsLayout = true }
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        tab.stackView.needsLayout = true
        updateScrollRegion(for: tab)
        resizePtyToViewport(for: tab)
    }

    func stopAllSessions() {
        for tab in tabs {
            let shouldKillUnpersistedSession = !shouldPersistSession(tab) && !isSessionVisibleOutsideTab(tab)
            stopRunningElapsedUpdates(for: tab)
            if shouldKillUnpersistedSession {
                tab.session.kill()
            } else {
                tab.session.stop()
            }
        }
    }

    func discardWindowRestoration(includingOtherWindows: Bool = false) {
        do {
            if includingOtherWindows {
                try sessionCatalog.discardAllWindowRestoration()
            } else {
                try sessionCatalog.discardWindowRestoration()
            }
        } catch {
            NSLog("Failed to discard Portal window restoration: \(error.localizedDescription)")
        }
    }

    var windowSessionRecord: SessionCatalog.Record? {
        activeTab.flatMap { shouldPersistSession($0) ? storedTab(from: $0) : nil }
    }
    var windowDirectory: URL { activeTab.map { URL(fileURLWithPath: $0.currentCwd) } ?? initialDirectory }
    var windowHostID: String? {
        guard let location = activeTab?.sessionRef.location else { return initialHostID }
        if case .sshHost(let id) = location { return id }
        return nil
    }
    var windowHosts: [TerminalHost] { sessionHosts }

    var activeSessionRef: SessionRef? { activeTab?.sessionRef }

    var openSessionRecords: [SessionCatalog.Record] {
        tabs.filter { !$0.hasExited && !$0.canReplaceFreshSession }.map(storedTab)
    }

    @discardableResult
    func activateOpenSession(_ sessionRef: SessionRef) -> Bool {
        guard let tab = tabs.first(where: { $0.sessionRef == sessionRef && !$0.hasExited }) else {
            return false
        }
        activateTab(tab.id)
        return true
    }

    @objc func clearCommandHistory(_ sender: Any?) {
        guard let tab = activeTab else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear command history on this host?"
        alert.informativeText = "This permanently removes successful commands stored on the active host. Session Up/Down history is unchanged."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        dismissCompletion()
        let location = tab.sessionRef.location
        completionQueue.async { [weak self] in
            guard let self else { return }
            let cleared = completionEngine.clearHistory(
                location: location
            )
            guard !cleared else { return }
            DispatchQueue.main.async {
                let error = NSAlert()
                error.alertStyle = .warning
                error.messageText = "Command history could not be cleared"
                error.runModal()
            }
        }
    }

    func beginWindowResizeTooltip() {
        isShowingResizeTooltip = true
        updateWindowResizeTooltip()
    }

    func updateWindowResizeTooltip() {
        guard isShowingResizeTooltip else { return }
        guard let tab = activeTab,
              let gridSize = terminalGridSize(for: tab),
              let window = view.window
        else {
            resizeTooltipView.isHidden = true
            return
        }

        let text = "\(gridSize.cols) cols x \(gridSize.rows) rows"
        let tooltipSize = resizeTooltipView.update(text: text)
        let windowPoint = window.convertFromScreen(NSRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        let point = view.convert(windowPoint, from: nil)

        resizeTooltipView.frame = NSRect(
            origin: tooltipOrigin(near: point, size: tooltipSize),
            size: tooltipSize
        )
        resizeTooltipView.isHidden = false
    }

    func endWindowResizeTooltip() {
        isShowingResizeTooltip = false
        resizeTooltipView.isHidden = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        handleRootLayout()
    }

    private func handleRootLayout() {
        if standalone {
            trafficLightBorderView.buttonFrames = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { type in
                    guard let button = view.window?.standardWindowButton(type), !button.isHidden else { return nil }
                    return trafficLightBorderView.convert(button.convert(button.bounds, to: nil), from: nil)
                }
        }
        for tab in tabs {
            tab.setToolbarInset(toolbarInset)
            updateScrollRegion(for: tab)
            resizePtyToViewport(for: tab)
        }
        updateCompletionAnchorForActiveTab()
        updateWindowResizeTooltip()
    }

    private func updateScrollRegion(for tab: TerminalTab) {
        tab.rootView.layoutSubtreeIfNeeded()
        tab.scrollView.layoutSubtreeIfNeeded()
        tab.scrollView.documentView?.layoutSubtreeIfNeeded()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let tab = tabs.first(where: { $0.inputView === textView }) else {
            return false
        }

        if tab.isFindMode {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                exitFindMode(in: tab)
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
                commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                selectFindResult(offset: 1, in: tab)
                return true
            }
            return false
        }

        if completionPopup.isShown {
            if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
                completionPopup.clearSelection()
                tab.inputView.clearMutedCompletionPreview()
                return false
            }
            if commandSelector == #selector(NSResponder.moveRight(_:)) {
                if completionPopup.selectedSuggestion != nil {
                    acceptSelectedCompletion(in: tab, continuingDirectories: true)
                    return true
                }
                if consumeOnlyCompletion(in: tab) {
                    return true
                }
                if let suggestion = completionPopup.selectNext() {
                    renderCompletionPreview(suggestion, in: tab)
                }
                return true
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                if let suggestion = completionPopup.selectPrevious() {
                    renderCompletionPreview(suggestion, in: tab)
                }
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                if let suggestion = completionPopup.selectNext() {
                    renderCompletionPreview(suggestion, in: tab)
                }
                return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                if deferCompletionAcceptanceUntilPendingRequestCompletes(in: tab) {
                    return true
                }
                if completionPopup.selectedSuggestion == nil {
                    if consumeOnlyCompletion(in: tab) {
                        return true
                    }
                    if canInsertCommandSeparator {
                        let cursor = tab.inputView.selectedRange().location
                        replace(range: NSRange(location: cursor, length: 0), with: " ", in: tab)
                        requestCompletion(in: tab, mode: .continuation)
                    } else if insertSharedCompletionPrefixIfAvailable(in: tab) {
                        return true
                    } else if let suggestion = completionPopup.selectNext() {
                        renderCompletionPreview(suggestion, in: tab)
                    }
                    return true
                }
                completeFromPopup(in: tab, continuingDirectories: true)
                return true
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                if let suggestion = completionPopup.selectPrevious() {
                    renderCompletionPreview(suggestion, in: tab)
                }
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
                commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                if shouldInsertLineContinuationNewline(in: textView) {
                    dismissCompletion()
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                if completionPopup.selectedSuggestion == nil {
                    dismissCompletion()
                    submitCommand(in: tab)
                    return true
                }
                acceptSelectedCompletion(in: tab)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                dismissCompletion()
                return true
            }
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)),
           isCommandRunning(in: tab) {
            interruptCommand(in: tab)
            return true
        }

        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            requestCompletion(in: tab, mode: .explicit)
            return true
        }
        if commandSelector == #selector(NSResponder.moveRight(_:)) {
            let selection = textView.selectedRange()
            if selection.length == 0,
               selection.location == (textView.string as NSString).length {
                requestCompletion(in: tab, mode: .rightArrow)
                return true
            }
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true ||
                shouldInsertLineContinuationNewline(in: textView) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                dismissCompletion()
                submitCommand(in: tab)
            }
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            return showPreviousCommand(in: tab)
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            return showNextCommand(in: tab)
        }
        return false
    }

    private func shouldInsertLineContinuationNewline(in textView: NSTextView) -> Bool {
        let selectedRange = textView.selectedRange()
        guard selectedRange.length == 0 else { return false }

        let input = textView.string as NSString
        guard selectedRange.location > 0,
              selectedRange.location <= input.length
        else {
            return false
        }

        let textBeforeCursor = input.substring(to: selectedRange.location) as NSString
        let currentLineRange = textBeforeCursor.range(
            of: "\n",
            options: [.backwards]
        )
        let lineStart = currentLineRange.location == NSNotFound
            ? 0
            : currentLineRange.location + currentLineRange.length
        let currentLine = textBeforeCursor.substring(from: lineStart)
        return currentLine.hasSuffix("\\")
    }

    func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        true
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingCompletion else { return }
        guard let textView = notification.object as? NSTextView,
              let tab = tabs.first(where: { $0.inputView === textView })
        else {
            dismissCompletion()
            return
        }
        tab.inputView.normalizePlainTextStorage()
        tab.inputView.clearMutedCompletionPreview()
        updateCommandInputHeight(for: tab)
        if tab.isFindMode {
            updateFindResults(in: tab, bounce: true)
            return
        }
        if completionPopup.isShown {
            updateCompletionAnchor(for: tab)
            requestCompletion(
                in: tab,
                mode: activeCompletionMode == .history ? .history : .filtering
            )
        } else if shouldStartAutomaticCompletion(in: textView) {
            requestCompletion(in: tab, mode: .automatic)
        } else {
            dismissCompletion()
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isApplyingCompletion,
              completionPopup.isShown,
              let textView = notification.object as? NSTextView,
              let tab = tabs.first(where: { $0.inputView === textView })
        else {
            return
        }

        let selectedRange = textView.selectedRange()
        guard selectedRange.length == 0 else {
            dismissCompletion()
            return
        }

        updateCompletionAnchor(for: tab)

        if let activeCompletionRange,
           selectedRange.location != activeCompletionRange.location + activeCompletionRange.length {
            tab.inputView.clearMutedCompletionPreview()
            requestCompletion(in: tab, mode: .filtering)
        }
    }

    func textShouldBeginEditing(_ textObject: NSText) -> Bool {
        guard let textView = textObject as? NSTextView,
              let tab = tabs.first(where: { $0.inputView === textView }),
              shouldSendInputToPty(in: tab)
        else {
            return true
        }
        focusInput(for: tab)
        return false
    }

    func newTab(at directoryURL: URL) {
        createTab(workingDirectory: directoryURL)
    }

    func newTab(
        at directoryURL: URL,
        running command: String,
        exitsShellAfterCompletion: Bool = false
    ) {
        createTab(
            workingDirectory: directoryURL,
            initialCommand: InitialCommand(
                command: command,
                exitsShellAfterCompletion: exitsShellAfterCompletion
            )
        )
    }

    @objc func findInHistory(_ sender: Any?) {
        guard let tab = activeTab else {
            NSSound.beep()
            return
        }
        enterFindMode(in: tab)
    }

    @objc func findNextInHistory(_ sender: Any?) {
        guard let tab = activeTab else {
            NSSound.beep()
            return
        }
        guard tab.isFindMode else {
            enterFindMode(in: tab)
            return
        }
        selectFindResult(offset: 1, in: tab)
    }

    @objc func findPreviousInHistory(_ sender: Any?) {
        guard let tab = activeTab else {
            NSSound.beep()
            return
        }
        guard tab.isFindMode else {
            enterFindMode(in: tab)
            return
        }
        selectFindResult(offset: -1, in: tab)
    }

    @objc private func closeFindMode(_ sender: Any?) {
        guard let tab = activeTab else { return }
        exitFindMode(in: tab)
    }

    @objc func exitActiveSession(_ sender: Any?) {
        guard let tab = activeTab, !tab.hasExited else {
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Exit this session?"
        alert.informativeText = "This permanently stops the shell session. Its output will remain visible in this tab."
        alert.addButton(withTitle: "Exit Session")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        tab.session.kill()
    }

    @objc func killClosedTabs(_ sender: Any?) {
        guard !closedTabs.isEmpty else {
            NSSound.beep()
            return
        }
        guard !isKillingClosedTabs else {
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Exit closed tabs?"
        alert.informativeText = "This will permanently stop \(closedTabs.count) closed shell session\(closedTabs.count == 1 ? "" : "s"). Visible tabs will not be exited."
        alert.addButton(withTitle: "Exit Closed Tabs")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let visibleSessionRefs = Set(sessionCatalog.visibleRecords().map(\.resolvedRef))
        let killTargets: [(stored: StoredTab, sessionRef: SessionRef)] = closedTabs.compactMap { stored in
            let storedRef = sessionRef(from: stored)
            guard !visibleSessionRefs.contains(storedRef) else { return nil }
            return (stored, storedRef)
        }
        guard !killTargets.isEmpty else {
            NSSound.beep()
            return
        }

        isKillingClosedTabs = true
        let targetRefs = Set(killTargets.map { $0.sessionRef })
        sessionCatalog.removeClosed(targetRefs)
        persistSessionState()

        sessionCleanupQueue.async { [weak self] in
            var failedTargets: [(stored: StoredTab, sessionRef: SessionRef, error: Error)] = []
            for target in killTargets {
                do {
                    try PtySession.killDetachedSession(sessionRef: target.sessionRef)
                } catch {
                    failedTargets.append((target.stored, target.sessionRef, error))
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isKillingClosedTabs = false

                if !failedTargets.isEmpty {
                    self.sessionCatalog.restoreClosed(failedTargets.map(\.stored))
                    self.persistSessionState()

                    let failureAlert = NSAlert()
                    failureAlert.alertStyle = .warning
                    failureAlert.messageText = "Some closed tabs could not be exited"
                    failureAlert.informativeText = failedTargets
                        .map { "\($0.stored.title): \($0.error.localizedDescription)" }
                        .joined(separator: "\n")
                    failureAlert.runModal()
                }
            }
        }
    }

    private func enterFindMode(in tab: TerminalTab) {
        dismissCompletion()
        if !tab.isFindMode {
            tab.isFindMode = true
            tab.findCommandDraft = tab.inputView.string
            tab.findQuery = ""
            tab.findResults = []
            tab.findResultIndex = nil
            setInput("", in: tab)
        }

        tab.commandLifecycle.apply(.resetHistorySelection)
        tab.commandBarView.layer?.backgroundColor = NSColor.selectedControlColor.withAlphaComponent(0.32).cgColor
        tab.findCloseButton.isHidden = false
        tab.inputView.setAccessibilityLabel("Terminal history find")
        updatePassthroughVisibility(for: tab)
        updateCommandBarVisibility(for: tab)
        updateFindResults(in: tab, bounce: false)
        focusInput(for: tab)
        tab.inputView.selectAll(nil)
    }

    private func exitFindMode(in tab: TerminalTab) {
        guard tab.isFindMode else { return }
        clearFindHighlight(in: tab)
        tab.isFindMode = false
        tab.findQuery = ""
        tab.findResults = []
        tab.findResultIndex = nil
        tab.commandBarView.layer?.backgroundColor = nil
        tab.findCloseButton.isHidden = true
        tab.inputView.setAccessibilityLabel("Terminal command input")
        setInput(tab.findCommandDraft, in: tab)
        tab.findCommandDraft = ""
        if tab.isShellReady {
            updateCommandBarDirectoryStatus(for: tab, forceRefresh: true)
        }
        updatePassthroughVisibility(for: tab)
        updateCommandBarVisibility(for: tab)
        focusInput(for: tab)
    }

    private func updateFindResults(in tab: TerminalTab, bounce: Bool) {
        guard tab.isFindMode else { return }
        tab.findQuery = tab.inputView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousResult = tab.findResultIndex.flatMap { index in
            tab.findResults.indices.contains(index) ? tab.findResults[index] : nil
        }

        tab.findResults = findResults(query: tab.findQuery, in: tab)
        if let previousResult,
           let index = tab.findResults.firstIndex(where: { findResult($0, hasSameAnchorAs: previousResult) }) {
            tab.findResultIndex = index
        } else {
            tab.findResultIndex = tab.findResults.isEmpty ? nil : 0
        }

        let selectedResult = tab.findResultIndex.flatMap { index in
            tab.findResults.indices.contains(index) ? tab.findResults[index] : nil
        }
        applyFindSelection(
            in: tab,
            bounce: bounce,
            scroll: !findResult(selectedResult, hasSameAnchorAs: previousResult)
        )
        updateFindStatus(in: tab)
    }

    private func findResult(_ lhs: FindResult?, hasSameAnchorAs rhs: FindResult?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return findResult(lhs, hasSameAnchorAs: rhs)
    }

    private func findResult(_ lhs: FindResult, hasSameAnchorAs rhs: FindResult) -> Bool {
        lhs.blockID == rhs.blockID
            && lhs.target == rhs.target
            && lhs.range.location == rhs.range.location
    }

    private func findResults(query: String, in tab: TerminalTab) -> [FindResult] {
        guard !query.isEmpty else { return [] }
        return tab.blocks.reversed().flatMap { block in
            findResults(in: block, query: query)
        }
    }

    private func findResults(in block: TerminalBlock, query: String) -> [FindResult] {
        let commandResults = matchRanges(in: block.command, query: query).map {
            FindResult(blockID: block.id, target: .command, range: $0)
        }
        let outputResults = matchRanges(in: block.output, query: query).map {
            FindResult(blockID: block.id, target: .output, range: $0)
        }
        return Array(outputResults.reversed()) + Array(commandResults.reversed())
    }

    private func matchRanges(in text: String, query: String) -> [NSRange] {
        let source = text as NSString
        let queryLength = (query as NSString).length
        guard source.length > 0, queryLength > 0 else { return [] }

        var results: [NSRange] = []
        var searchRange = NSRange(location: 0, length: source.length)
        while searchRange.length > 0 {
            let range = source.range(of: query, options: [.caseInsensitive], range: searchRange)
            guard range.location != NSNotFound else { break }
            results.append(range)
            let nextLocation = range.location + max(1, range.length)
            searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
        }
        return results
    }

    private func selectFindResult(offset: Int, in tab: TerminalTab) {
        guard tab.isFindMode, !tab.findResults.isEmpty else {
            NSSound.beep()
            return
        }
        let current = tab.findResultIndex ?? 0
        tab.findResultIndex = (current + offset + tab.findResults.count) % tab.findResults.count
        applyFindSelection(in: tab, bounce: true, scroll: true)
        updateFindStatus(in: tab)
    }

    private func applyFindSelection(in tab: TerminalTab, bounce: Bool, scroll: Bool) {
        let selectedResult = tab.findResultIndex.flatMap { index in
            tab.findResults.indices.contains(index) ? tab.findResults[index] : nil
        }
        for (blockID, blockView) in tab.blockViews {
            if blockID == selectedResult?.blockID {
                blockView.setFindSelection(
                    target: selectedResult?.target,
                    range: selectedResult?.range,
                    bounce: bounce
                )
            } else {
                blockView.setFindSelection(target: nil)
            }
        }
        guard let selectedResult,
              let blockView = tab.blockViews[selectedResult.blockID]
        else {
            return
        }
        if scroll {
            blockView.scrollFindSelectionToVisible()
        }
    }

    private func clearFindHighlight(in tab: TerminalTab) {
        for blockView in tab.blockViews.values {
            blockView.setFindSelection(target: nil)
        }
    }

    private func updateFindStatus(in tab: TerminalTab) {
        let status: String
        if tab.findQuery.isEmpty {
            status = "Find in History"
        } else if let index = tab.findResultIndex {
            status = "\(index + 1) of \(tab.findResults.count)"
        } else {
            status = "0 results"
        }
        setCommandBarStatusText(status, in: tab)
    }

    @objc func clearActiveTab(_ sender: Any?) {
        guard let tab = activeTab, !tab.blocks.isEmpty else { return }

        clearFindHighlight(in: tab)
        tab.session.clearHistory()
        let blockIDsToKeep = Set(tab.blocks.compactMap { block -> UUID? in
            if block.id == tab.activeBlockID || block.id == tab.pendingBlockID {
                return block.id
            }
            if case .running = block.state {
                return block.id
            }
            return nil
        })

        tab.commandLifecycle.apply(.clearTranscript(keeping: blockIDsToKeep))
        tab.blockViews.removeAll()
        rebuildBlockViews(for: tab)
        updateFindResults(in: tab, bounce: false)
        scrollToBottom(tab)
        focusInput(for: tab)
    }

    @discardableResult
    private func closeTab(withID id: UUID, createsReplacement: Bool = true) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id })
        else {
            return false
        }
        let tab = tabs[index]
        let isVisibleOutsideTab = isSessionVisibleOutsideTab(tab)
        let shouldPersistTab = shouldPersistSession(tab)
        if shouldPersistTab && shouldStoreSession(tab) && !isVisibleOutsideTab {
            sessionCatalog.appendClosed(storedTab(from: tab))
        }
        stopRunningElapsedUpdates(for: tab)
        if !shouldPersistTab && !isVisibleOutsideTab {
            tab.session.kill()
        } else {
            tab.session.stop()
        }
        let wasActive = activeTabID == tab.id
        tab.rootView.removeFromSuperview()
        tabs.remove(at: index)
        onActivityChange?()

        guard !tabs.isEmpty else {
            activeTabID = nil
                persistSessionState()
            if createsReplacement { createTab() }
            return true
        }

        if wasActive {
            let nextIndex = min(index, tabs.count - 1)
            activateTab(tabs[nextIndex].id)
        } else {
            }
        persistSessionState()
        configureSessionPickerIfPossible()
        return true
    }

    var isShowingSessionPicker: Bool { activeTab?.sessionPickerView.isHidden == false }

    private var activeTab: TerminalTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    private func restoreSessionState() {
        if let restoredSession {
            createTab(from: restoredSession, activates: true, persists: true)
            return
        }
        let restoration = sessionCatalog.restore(restoresPersistedWindow: restoresPersistedWindow)
        let tabsToRestore = restoration.tabs

        if tabsToRestore.isEmpty {
            createTab(initialCommand: launchCommand.map { InitialCommand(command: $0, exitsShellAfterCompletion: false) },
                      showsSessionPicker: standalone && !skipsSessionPicker && launchCommand == nil && initialHostID == nil)
            return
        }

        let firstTab = tabsToRestore[0]
        createTab(from: firstTab, activates: true, persists: false)

        let firstRef = sessionRef(from: firstTab)
        let remainingTabs = tabsToRestore.filter { sessionRef(from: $0) != firstRef }
        restoreSessionTabs(
            remainingTabs,
            activeSessionID: restoration.activeSessionID
        )
    }

    private func restoreSessionTabs(
        _ storedTabs: [StoredTab],
        activeSessionID: String?
    ) {
        for storedTab in storedTabs {
            createTab(from: storedTab, activates: false, persists: false)
        }

        if let activeSessionID,
           let activeTab = tabs.first(where: { $0.sessionID == activeSessionID }) {
            activateTab(activeTab.id, persists: false)
        }
        persistSessionState()
    }

    private func createTab(from storedTab: StoredTab, activates: Bool, persists: Bool) {
        createTab(
            workingDirectory: URL(fileURLWithPath: storedTab.cwd),
            sessionRef: sessionRef(from: storedTab),
            title: storedTab.title,
            createdAt: storedTab.createdAt ?? Date(),
            commandCount: storedTab.commandCount ?? 0,
            lastCommandAt: storedTab.lastCommandAt,
            commandHistory: storedTab.commandHistory ?? [],
            commandRunDates: storedTab.commandRunDates ?? [:],
            showsSessionPicker: false,
            activates: activates,
            persists: persists
        )
    }

    private func persistSessionState() {
        do {
            try sessionCatalog.persist(
                visibleTabs: tabs.filter(shouldStoreSession).map(storedTab(from:)),
                activeSessionRef: activeTab.flatMap { shouldStoreSession($0) ? $0.sessionRef : nil }
            )
            publishVisibleSessionState()
        } catch {
            NSLog("Failed to persist Portal session state: \(error.localizedDescription)")
        }
    }

    private func shouldPersistSession(_ tab: TerminalTab) -> Bool {
        tab.commandCount > 0 && !tab.hasExited && !sessionCatalog.isExited(tab.sessionRef)
    }

    private func shouldStoreSession(_ tab: TerminalTab) -> Bool {
        shouldPersistSession(tab)
    }

    private func shouldPersistStoredSession(_ tab: StoredTab) -> Bool {
        sessionCatalog.shouldPersist(tab)
    }

    private func publishVisibleSessionState() {
        for tab in tabs where shouldPersistSession(tab) {
            tab.session.updateState(
                title: standardTabTitle(tab.title, in: tab),
                cwd: tab.currentCwd,
                createdAt: tab.createdAt,
                commandCount: tab.commandCount,
                lastCommandAt: tab.lastCommandAt,
                runningCommand: runningCommand(in: tab),
                commandHistory: tab.commandHistory
            )
        }
    }

    private func storedTab(from tab: TerminalTab) -> StoredTab {
        StoredTab(
            sessionRef: tab.sessionRef,
            sessionID: tab.sessionID,
            title: standardTabTitle(tab.title, in: tab),
            cwd: tab.currentCwd,
            windowID: nil,
            createdAt: tab.createdAt,
            commandCount: tab.commandCount,
            lastCommandAt: tab.lastCommandAt,
            runningCommand: runningCommand(in: tab),
            commandHistory: tab.commandHistory,
            commandRunDates: tab.commandLifecycle.state.commandRunDates
        )
    }

    private func sessionRef(from tab: StoredTab) -> SessionRef {
        tab.resolvedRef
    }

    private func isSessionVisibleOutsideTab(_ tab: TerminalTab) -> Bool {
        if tabs.contains(where: { $0.id != tab.id && $0.sessionRef == tab.sessionRef }) {
            return true
        }
        return sessionCatalog.isVisibleOutsideCurrentWindow(tab.sessionRef)
    }

    private func runningCommand(in tab: TerminalTab) -> String? {
        latestRunningBlock(in: tab)?.command
    }

    private static func sessionStateURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Portal/Terminal", isDirectory: true)
            .appendingPathComponent("sessions.json", isDirectory: false)
    }

    private func createTab(
        workingDirectory: URL? = nil,
        sessionRef: SessionRef? = nil,
        title: String? = nil,
        createdAt: Date = Date(),
        commandCount: Int = 0,
        lastCommandAt: Date? = nil,
        commandHistory: [String] = [],
        commandRunDates: [String: Date] = [:],
        initialCommand: InitialCommand? = nil,
        shellPath: String? = nil,
        showsSessionPicker: Bool = false,
        activates: Bool = true,
        persists: Bool = true
    ) {
        guard !standalone || tabs.isEmpty else { return }
        let isExistingSession = sessionRef != nil
        let sessionRef = sessionRef ?? SessionRef(location: initialHostID.map(SessionLocation.sshHost) ?? .local,
                                                 sessionID: UUID().uuidString)
        let directoryURL = (workingDirectory ?? initialDirectory).standardizedFileURL
        let directoryPath = directoryURL.path
        let tab = TerminalTab(
            title: title ?? titleForDirectory(directoryPath),
            delegate: self,
            sessionRef: sessionRef,
            createdAt: createdAt,
            commandCount: commandCount,
            lastCommandAt: lastCommandAt,
            commandHistory: commandHistory,
            commandRunDates: commandRunDates
        )
        tab.commandBarView.layer?.backgroundColor = nil
        tab.commandLifecycle.apply(.cwdChanged(directoryPath))
        tab.findCloseButton.target = self
        tab.findCloseButton.action = #selector(closeFindMode(_:))
        setCommandBarStatusText(isExistingSession ? "Rejoining session..." : "Starting shell...", in: tab)
        tab.rootView.isHidden = !activates
        tabs.append(tab)
        if let initialCommand {
            initialCommands[tab.id] = initialCommand
        }
        configureSession(for: tab)
        configureInterruptHandling(for: tab)
        installTabView(tab)
        if activates {
            activateTab(tab.id, persists: persists)
        }
        startShell(for: tab, workingDirectory: directoryURL, shellPath: shellPath)
        if showsSessionPicker {
            configureSessionPicker(for: tab)
        }
        if persists {
            persistSessionState()
        }
    }

    var otherOpenSessionRefs: () -> Set<SessionRef> = { [] }

    var sessionPickerExclusions: Set<SessionRef> {
        Set(tabs.map(\.sessionRef)).union(otherOpenSessionRefs())
    }

    private func configureSessionPicker(for tab: TerminalTab) {
        let model = SessionPickerModel(inventory: sessionPickerInventory)
        sessionPickerModelsByTab[tab.id]?.invalidate()
        sessionPickerModelsByTab[tab.id] = model
        let initial = localSessionCandidates(excluding: tab).filter {
            if case .sshHost = $0.sessionRef.location { return false }
            return true
        }
        let excluded = sessionPickerExclusions
        let tabID = tab.id
        let localHostName = Host.current().localizedName ?? "This Mac"
        model.refresh(
            initial: initial,
            excluding: excluded,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            loadLocal: {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        continuation.resume(returning: try? Self.daemonSessionCandidates(
                            hostTitle: localHostName
                        ))
                    }
                }
            },
            remoteLoaders: Dictionary(uniqueKeysWithValues: sessionHosts.map { host in
                (SessionLocation.sshHost(host.id), { @Sendable in
                    await Self.sshSessionCandidates(host: host)
                })
            }),
            isAvailable: { [weak self] sessionRef in
                guard let self else { return false }
                return !self.sessionPickerExclusions.contains(sessionRef)
                    && !self.killingSessionRefs.contains(sessionRef)
                    && !self.sessionCatalog.isExited(sessionRef)
            },
            onUpdate: { [weak self] snapshot in
                guard let self,
                      let tab = self.tabs.first(where: { $0.id == tabID }),
                      tab.commandCount == 0
                else {
                    return
                }
                self.renderSessionPicker(snapshot.offeringNewSessions(on: self.sessionHosts), for: tab)
            }
        )
    }

    private func renderSessionPicker(_ snapshot: SessionPickerSnapshot, for tab: TerminalTab) {
        tab.canReplaceFreshSession = true
        let candidates = snapshot.sections.flatMap { section in
            section.items.map(\.candidate) + [section.newSession].compactMap { $0 }
        }
        sessionPickerCandidatesByTab[tab.id] = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.sessionRef, $0) }
        )
        for view in tab.sessionPickerStack.arrangedSubviews {
            tab.sessionPickerStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        var rowCount = 0
        var emptyRowCount = 0
        for section in snapshot.sections {
            let hostTitle = section.title
            let header = NSTextField(labelWithString: hostTitle)
            header.attributedStringValue = hostPrefixAttributedString(
                header.stringValue,
                color: TahoeGlassPalette.titleTextActive
            )
            let headerStack = NSStackView()
            headerStack.orientation = .horizontal
            headerStack.alignment = .centerY
            headerStack.spacing = 4
            headerStack.heightAnchor.constraint(equalToConstant: 20).isActive = true
            if section.location != .local {
                let icon = NSImageView()
                icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
                icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
                icon.contentTintColor = appearanceAlpha(TahoeGlassPalette.titleTextActive, 0.34)
                headerStack.addArrangedSubview(icon)
            }
            headerStack.addArrangedSubview(header)
            if snapshot.loadingLocations.contains(section.location) {
                let spinner = NSProgressIndicator()
                spinner.style = .spinning
                spinner.controlSize = .small
                spinner.setAccessibilityLabel("Loading sessions on \(hostTitle)")
                spinner.startAnimation(nil)
                headerStack.addArrangedSubview(spinner)
            }
            if let candidate = section.newSession {
                let button = SessionHeaderAddButton(
                    sessionRef: candidate.sessionRef,
                    hostName: hostTitle
                )
                button.target = self
                button.action = #selector(startNewSessionFromPicker(_:))
                headerStack.addArrangedSubview(button)
            }
            tab.sessionPickerStack.addArrangedSubview(headerStack)

            if section.items.isEmpty {
                let emptyRow = NSView()
                emptyRow.translatesAutoresizingMaskIntoConstraints = false
                let emptyLabel = NSTextField(labelWithString: snapshot.loadingLocations.contains(section.location) ? "Loading sessions…" : "No active sessions")
                emptyLabel.font = .systemFont(ofSize: 11, weight: .regular)
                emptyLabel.textColor = appearanceAlpha(TahoeGlassPalette.titleTextActive, 0.22)
                emptyLabel.translatesAutoresizingMaskIntoConstraints = false
                emptyRow.addSubview(emptyLabel)
                NSLayoutConstraint.activate([
                    emptyRow.heightAnchor.constraint(equalToConstant: 82),
                    emptyLabel.leadingAnchor.constraint(equalTo: emptyRow.leadingAnchor, constant: 46),
                    emptyLabel.centerYAnchor.constraint(equalTo: emptyRow.centerYAnchor)
                ])
                tab.sessionPickerStack.addArrangedSubview(emptyRow)
                emptyRow.widthAnchor.constraint(equalTo: tab.sessionPickerStack.widthAnchor).isActive = true
                emptyRowCount += 1
            }

            for rowItems in section.items.chunked(into: 4).reversed() {
                let buttons = rowItems.map { item in
                    let candidate = item.candidate
                    let button = SessionCandidateButton(
                        sessionRef: candidate.sessionRef,
                        title: item.title,
                        subtitle: item.subtitle,
                        metadata: item.metadata
                    )
                    button.target = self
                    button.action = #selector(attachSessionFromPicker(_:))
                    if candidate.canExit,
                       !sessionCatalog.isVisibleOutsideCurrentWindow(candidate.sessionRef) {
                        button.menu = sessionCandidateMenu(for: candidate.sessionRef)
                    }
                    return button
                }

                let row = SessionCandidateRowView(buttons: buttons)
                tab.sessionPickerStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: tab.sessionPickerStack.widthAnchor).isActive = true
                rowCount += 1
            }
        }

        tab.sessionPickerView.isHidden = false
        tab.sessionPickerView.restoreSelection()
        let arrangedViewCount = rowCount + emptyRowCount + snapshot.sections.count
        let spacing = max(0, arrangedViewCount - 1) * 10
        tab.sessionPickerHeightConstraint?.constant = CGFloat(
            16 + (rowCount + emptyRowCount) * 82 + snapshot.sections.count * 20 + spacing
        )
        tab.rootView.needsLayout = true
    }

    private func hideSessionPicker(for tab: TerminalTab) {
        tab.canReplaceFreshSession = false
        tab.sessionPickerView.clearSelection()
        sessionPickerModelsByTab.removeValue(forKey: tab.id)?.invalidate()
        sessionPickerCandidatesByTab.removeValue(forKey: tab.id)
        tab.sessionPickerView.isHidden = true
        tab.sessionPickerHeightConstraint?.constant = 0
        for view in tab.sessionPickerStack.arrangedSubviews {
            tab.sessionPickerStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        tab.rootView.needsLayout = true
    }

    private func localSessionCandidates(excluding tab: TerminalTab) -> [SessionPickerCandidate] {
        var seen = Set(tabs.map(\.sessionRef))
        var candidates: [SessionPickerCandidate] = []

        for visible in sessionCatalog.visibleRecords() {
            let visibleRef = sessionRef(from: visible)
            guard shouldPersistStoredSession(visible),
                  visible.windowID != nil,
                  visible.windowID != windowID,
                  seen.insert(visibleRef).inserted
            else { continue }
            candidates.append(SessionPickerCandidate(
                sessionRef: visibleRef,
                hostTitle: hostname(for: visibleRef) ?? Host.current().localizedName ?? "This Mac",
                title: visible.title,
                cwd: visible.cwd,
                isClosed: false,
                createdAt: visible.createdAt,
                commandCount: visible.commandCount ?? 0,
                lastCommandAt: visible.lastCommandAt,
                runningCommand: visible.runningCommand,
                commandHistory: visible.commandHistory ?? [],
                action: .attach
            ))
        }

        for closed in closedTabs.reversed() {
            let closedRef = sessionRef(from: closed)
            guard shouldPersistStoredSession(closed),
                  seen.insert(closedRef).inserted
            else { continue }
            candidates.append(SessionPickerCandidate(
                sessionRef: closedRef,
                hostTitle: hostname(for: closedRef) ?? Host.current().localizedName ?? "This Mac",
                title: closed.title,
                cwd: closed.cwd,
                isClosed: true,
                createdAt: closed.createdAt,
                commandCount: closed.commandCount ?? 0,
                lastCommandAt: closed.lastCommandAt,
                runningCommand: closed.runningCommand,
                commandHistory: closed.commandHistory ?? [],
                action: .attach
            ))
        }

        return candidates
    }

    private static func daemonSessionCandidates(hostTitle: String) throws -> [SessionPickerCandidate] {
        try PtySession.listSessions().map { session in
            let sessionRef = SessionRef(
                location: .local,
                sessionID: session.sessionID
            )
            return SessionPickerCandidate(
                sessionRef: sessionRef,
                hostTitle: hostTitle,
                title: session.title,
                cwd: session.cwd,
                isClosed: false,
                createdAt: session.createdAt,
                commandCount: session.commandCount,
                lastCommandAt: session.lastCommandAt,
                runningCommand: session.runningCommand,
                commandHistory: session.commandHistory,
                action: .attach,
                attachedClientCount: session.attachedClientCount
            )
        }
    }

    private static func sshSessionCandidates(host: TerminalHost) async -> [SessionPickerCandidate]? {
        await Task.detached(priority: .utility) {
            var candidates: [SessionPickerCandidate] = []
            do {
                let location = SessionLocation.sshHost(host.id)
                guard let sessions = try? PtySession.listSessions(location: location) else { return nil }
                candidates.append(SessionPickerCandidate(
                    sessionRef: SessionRef(location: location, sessionID: "new", hostName: host.name),
                    hostTitle: host.name, title: "New session", cwd: host.directory,
                    isClosed: false, commandCount: 0, runningCommand: nil,
                    commandHistory: [], action: .create
                ))
                candidates += sessions.map {
                    SessionPickerCandidate(
                        sessionRef: SessionRef(location: location, sessionID: $0.sessionID, hostName: host.name),
                        hostTitle: host.name, title: $0.title, cwd: $0.cwd,
                        isClosed: false, createdAt: $0.createdAt, commandCount: $0.commandCount,
                        lastCommandAt: $0.lastCommandAt, runningCommand: $0.runningCommand,
                        commandHistory: $0.commandHistory, action: .attach,
                        attachedClientCount: $0.attachedClientCount
                    )
                }
            }
            return candidates
        }.value
    }

    private func hostname(for sessionRef: SessionRef) -> String? {
        switch sessionRef.location {
        case .local:
            return nil
        case .sshHost(let hostID):
            guard let host = PtySession.loadSSHHosts().hosts.first(where: { $0.id == hostID })
            else { return nil }
            return host.hostname.isEmpty ? host.alias : host.hostname
        }
    }

    @objc private func attachSessionFromPicker(_ sender: SessionCandidateButton) {
        guard let tab = activeTab,
              tab.canReplaceFreshSession,
              tab.blocks.isEmpty
        else {
            NSSound.beep()
            return
        }

        guard let candidate = sessionPickerCandidatesByTab[tab.id]?[sender.sessionRef]
        else {
            NSSound.beep()
            return
        }

        attachSessionFromPicker(candidate, in: tab)
    }

    @objc private func startNewSessionFromPicker(_ sender: SessionHeaderAddButton) {
        guard let tab = activeTab,
              tab.canReplaceFreshSession,
              tab.blocks.isEmpty,
              let candidate = sessionPickerCandidatesByTab[tab.id]?[sender.sessionRef]
        else {
            NSSound.beep()
            return
        }

        attachSessionFromPicker(candidate, in: tab)
    }

    private func attachSessionFromPicker(_ candidate: SessionPickerCandidate, in tab: TerminalTab) {
        switch candidate.action {
        case .attach:
            replaceFreshSession(in: tab, with: candidate)
        case .create:
            var candidate = candidate
            candidate.sessionRef.sessionID = UUID().uuidString
            replaceFreshSession(
                in: tab,
                with: candidate
            )
        }
    }

    private func sessionCandidateMenu(for sessionRef: SessionRef) -> NSMenu {
        let menu = NSMenu()
        let connectItem = menu.addItem(
            withTitle: "Connect",
            action: #selector(connectSessionCandidate(_:)),
            keyEquivalent: ""
        )
        connectItem.target = self
        connectItem.representedObject = sessionRef
        menu.addItem(.separator())
        let killItem = menu.addItem(
            withTitle: "Exit",
            action: #selector(killSessionCandidate(_:)),
            keyEquivalent: ""
        )
        killItem.target = self
        killItem.representedObject = sessionRef
        return menu
    }

    @objc private func connectSessionCandidate(_ sender: NSMenuItem) {
        guard let sessionRef = sender.representedObject as? SessionRef,
              let tab = activeTab,
              tab.canReplaceFreshSession,
              tab.blocks.isEmpty,
              let candidate = sessionPickerCandidatesByTab[tab.id]?[sessionRef],
              candidate.action == .attach
        else {
            NSSound.beep()
            return
        }

        replaceFreshSession(in: tab, with: candidate)
    }

    @objc private func killSessionCandidate(_ sender: NSMenuItem) {
        guard let sessionRef = sender.representedObject as? SessionRef,
              let tab = activeTab,
              let candidate = sessionPickerCandidatesByTab[tab.id]?[sessionRef],
              candidate.canExit,
              !sessionCatalog.isVisibleOutsideCurrentWindow(sessionRef)
        else {
            NSSound.beep()
            return
        }

        let stored = closedTabs.first(where: { self.sessionRef(from: $0) == sessionRef })
        killingSessionRefs.insert(sessionRef)
        removeClosedSession(sessionRef)
        persistSessionState()
        configureSessionPickerIfPossible()

        Task { [weak self] in
            do {
                try await Task.detached {
                    try PtySession.killDetachedSession(sessionRef: sessionRef)
                }.value
                guard let self else { return }
                self.killingSessionRefs.remove(sessionRef)
                self.removeExitedSessionFromPersistentHistory(sessionRef)
                self.configureSessionPickerIfPossible()
            } catch {
                guard let self else { return }
                self.killingSessionRefs.remove(sessionRef)
                if let stored {
                    self.sessionCatalog.restoreClosed([stored])
                }
                self.persistSessionState()
                self.configureSessionPickerIfPossible()
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Session could not be exited"
                alert.informativeText = "\(candidate.title): \(error.localizedDescription)"
                alert.runModal()
            }
        }
    }

    private func configureSessionPickerIfPossible() {
        guard let tab = activeTab,
              tab.canReplaceFreshSession,
              tab.blocks.isEmpty
        else {
            return
        }
        configureSessionPicker(for: tab)
    }

    private func replaceFreshSession(
        in tab: TerminalTab,
        with candidate: SessionPickerCandidate,
        shellPath: String? = nil
    ) {
        tab.session.kill()

        hideSessionPicker(for: tab)
        clearCommandInput(in: tab)
        tab.pendingShellInitialization = nil
        tab.wasCreatedInThisController = candidate.action == .create
        tab.sessionRef = candidate.sessionRef
        tab.session = PtySession(sessionRef: candidate.sessionRef)
        tab.title = candidate.title
        tab.hasUnviewedCompletion = false
        tab.createdAt = candidate.createdAt ?? Date()
        tab.commandLifecycle.apply(.replaceSession(
            cwd: candidate.cwd,
            commandCount: candidate.commandCount,
            lastCommandAt: candidate.lastCommandAt,
            commandHistory: candidate.commandHistory,
            commandRunDates: (sessionCatalog.visibleRecords() + closedTabs).first { $0.resolvedRef == candidate.sessionRef }?.commandRunDates ?? [:]
        ))
        resetTranscriptViews(for: tab)
        setCommandBarStatusText(candidate.action == .attach ? "Rejoining session..." : "Starting shell...", in: tab)
        tab.isTerminalControlActive = false
        tab.outputProcessor.resetForReplay(
            fallbackCommand: candidate.runningCommand ?? candidate.commandHistory.last
        )
        configureSession(for: tab)
        configureInterruptHandling(for: tab)
        updateTabTitle(candidate.title, detail: candidate.cwd, in: tab)
        removeClosedSession(candidate.sessionRef)
        startShell(
            for: tab,
            workingDirectory: URL(fileURLWithPath: candidate.cwd),
            shellPath: shellPath
        )
        persistSessionState()
    }

    private func resetTranscriptViews(for tab: TerminalTab) {
        tab.commandSeparator.blockAbove = nil
        tab.blockViews.removeAll()
        for view in tab.stackView.arrangedSubviews {
            tab.stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func removeClosedSession(_ sessionRef: SessionRef) {
        sessionCatalog.removeClosed(sessionRef)
    }

    private func removeExitedSessionFromPersistentHistory(_ sessionRef: SessionRef) {
        guard sessionCatalog.markExited(sessionRef) else { return }
        persistSessionState()
    }

    private func installTabView(_ tab: TerminalTab) {
        contentContainer.addSubview(tab.rootView)
        NSLayoutConstraint.activate([
            tab.rootView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            tab.rootView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            tab.rootView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            tab.rootView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
    }

    private func installSessionPickerMouseDownMonitor() {
        sessionPickerMouseDownMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self,
                  event.window === self.view.window,
                  let button = self.sessionPickerButton(atWindowPoint: event.locationInWindow)
            else {
                return event
            }

            if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
                guard let menu = button.menu else { return event }
                NSMenu.popUpContextMenu(menu, with: event, for: button)
            } else {
                self.attachSessionFromPicker(button)
            }
            return nil
        }
    }

    private func installCommandFocusMonitor() {
        commandFocusMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseUp, .rightMouseUp]
        ) { [weak self] event in
            guard let self,
                  event.window === self.view.window,
                  (event.type != .keyDown || self.shouldRestoreCommandFocus)
            else {
                return event
            }

            switch event.type {
            case .keyDown:
                if !self.completionPopup.isShown,
                   self.activeTab?.sessionPickerView.handleKeyEvent(event) == true {
                    return nil
                }
                self.activeTab?.sessionPickerView.clearSelection()
                if self.handleHistoryKeyEvent(event) {
                    return nil
                }
                if self.shouldRedirectKeyEventToCommandInput(event) {
                    self.restoreCommandFocusIfNeeded()
                }
            case .leftMouseUp, .rightMouseUp:
                if self.shouldRestoreCommandFocus(afterMouseEvent: event) {
                    DispatchQueue.main.async { [weak self] in
                        guard let self,
                              !self.hasSelectedTranscriptText()
                        else {
                            return
                        }
                        self.restoreCommandFocusIfNeeded()
                    }
                }
            default:
                break
            }

            return event
        }
    }

    private func handleHistoryKeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.control],
              event.charactersIgnoringModifiers?.lowercased() == "r",
              let tab = activeTab,
              tab.isShellReady,
              !tab.isReplayingHistory,
              !tab.isTerminalControlActive
        else {
            return false
        }
        focusInput(for: tab)
        if completionPopup.isShown, activeCompletionMode == .history {
            if let suggestion = completionPopup.selectNext() {
                renderCompletionPreview(suggestion, in: tab)
            }
        } else {
            requestCompletion(in: tab, mode: .history)
        }
        return true
    }

    private func shouldRedirectKeyEventToCommandInput(_ event: NSEvent) -> Bool {
        guard let tab = activeTab,
              shouldRestoreCommandFocus,
              !isCommandFocusCurrent(for: tab)
        else {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return !flags.contains(.command)
    }

    private func shouldRestoreCommandFocus(afterMouseEvent event: NSEvent) -> Bool {
        guard let tab = activeTab,
              shouldRestoreCommandFocus,
              let hitView = hitView(for: event),
              hitView.isDescendant(of: view),
              !isCommandInputView(hitView, in: tab),
              !isSelectableTranscriptView(hitView)
        else {
            return false
        }

        return true
    }

    private func hasSelectedTranscriptText() -> Bool {
        selectedTranscriptText() != nil
    }

    private func selectedTranscriptText() -> String? {
        guard let tab = activeTab,
              let firstResponder = view.window?.firstResponder
        else {
            return nil
        }
        for block in tab.blocks {
            if let selectedText = tab.blockViews[block.id]?.selectedTextForCopy(firstResponder: firstResponder) {
                return selectedText
            }
        }
        return nil
    }

    private var shouldRestoreCommandFocus: Bool {
        guard let window = view.window,
              let responder = window.firstResponder as? NSView,
              responder.isDescendant(of: view) else { return false }
        return NSApp.isActive && window.isKeyWindow && NSApp.modalWindow == nil
    }

    private func restoreCommandFocusIfNeeded() {
        guard shouldRestoreCommandFocus,
              let tab = activeTab,
              !isCommandFocusCurrent(for: tab)
        else {
            return
        }
        focusInput(for: tab)
    }

    private func isCommandFocusCurrent(for tab: TerminalTab) -> Bool {
        guard let firstResponder = view.window?.firstResponder else { return false }
        return firstResponder === commandFocusTarget(for: tab)
    }

    private func commandFocusTarget(for tab: TerminalTab) -> NSResponder {
        shouldSendInputToPty(in: tab) ? tab.ptyPassthroughView : tab.inputView
    }

    private func hitView(for event: NSEvent) -> NSView? {
        guard let contentView = event.window?.contentView else { return nil }
        let point = contentView.convert(event.locationInWindow, from: nil)
        return contentView.hitTest(point)
    }

    private func sessionPickerButton(atWindowPoint point: NSPoint) -> SessionCandidateButton? {
        guard let tab = activeTab,
              !tab.sessionPickerView.isHidden
        else {
            return nil
        }

        let pickerPoint = tab.sessionPickerView.convert(point, from: nil)
        return tab.sessionPickerView.candidateButton(at: pickerPoint)
    }

    private func isCommandInputView(_ view: NSView, in tab: TerminalTab) -> Bool {
        view === tab.inputView || view.isDescendant(of: tab.inputView)
    }

    private func isSelectableTranscriptView(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let view = current {
            if view is BlockOutputTextView
                || view is SelectableBlockTextField
                || view is GitTreeCanvas {
                return true
            }
            current = view.superview
        }
        return false
    }

    private func activateTab(_ id: UUID, persists: Bool = true) {
        activeTabID = id
        markActiveTerminalViewed()
        discardUntouchedSessions(except: id)
        for tab in tabs {
            tab.rootView.isHidden = tab.id != id
        }
        if let tab = activeTab {
            applyGitTreeVisibility(for: tab)
            focusInput(for: tab)
            refreshVisibleCommandBarGitStatus(for: tab)
        }
        if persists {
            persistSessionState()
        }
    }

    private func configureSession(for tab: TerminalTab) {
        let configuredSessionRef = tab.sessionRef
        tab.outputProcessor.onEvent = { [weak self, weak tab] event in
            guard let self, let tab else { return }
            self.handleOutputProcessorEvent(event, in: tab)
        }
        tab.outputProcessor.onTerminalResponse = { [weak tab] response in
            tab?.session.write(response, suppressEcho: true)
        }
        tab.session.onConnectionChange = { [weak self, weak tab] connected in
            guard let self, let tab else { return }
            tab.inputView.isEditable = connected
            if connected {
                self.resizePtyToViewport(for: tab)
                self.updateCommandBarDirectoryStatus(for: tab, forceRefresh: true)
            } else {
                self.dismissCompletion()
                self.setCommandBarStatusText("Disconnected — reconnecting…", in: tab)
            }
        }
        tab.session.onOutput = { [weak self, weak outputProcessor = tab.outputProcessor] text in
            outputProcessor?.enqueueShellOutput(text)
            guard !text.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in self?.onOutputActivity?() }
        }
        tab.session.onHistoryOutput = { [weak self, weak tab] text in
            DispatchQueue.main.async { [weak self, weak tab] in
                guard let self, let tab else { return }
                tab.commandLifecycle.apply(.beginHistoryReplay)
                self.resetTranscriptViews(for: tab)
                self.updateCommandBarVisibility(for: tab)
            }
            tab?.outputProcessor.replayShellOutput(text) { [weak self, weak tab] in
                guard let self, let tab else { return }
                self.finishHistoryReplay(in: tab)
            }
        }
        tab.session.onExit = { [weak self, weak tab] status in
            guard let self, let tab else { return }
            guard tab.sessionRef == configuredSessionRef else { return }
            guard !tab.hasExited else { return }
            tab.interruptedBlockID = nil
            let exitChange = tab.commandLifecycle.apply(.shellExited(status: status, at: Date()))
            if !exitChange.finishedBlockIDs.isEmpty && !tab.isReplayingHistory {
                tab.hasUnviewedCompletion = !(self.isTerminalVisible && self.activeTabID == tab.id && self.view.window?.isKeyWindow == true)
            }
            tab.hostHistoryOptOutBlockIDs.subtract(exitChange.finishedBlockIDs)
            tab.inputView.isEditable = false
            tab.inputView.isSelectable = false
            self.removeExitedSessionFromPersistentHistory(configuredSessionRef)
            tab.outputProcessor.flushAndFinish { [weak self, weak tab] in
                guard let self, let tab else { return }
                guard tab.sessionRef == configuredSessionRef else { return }
                self.setCommandBarStatusText("Shell exited with status \(status)", in: tab)
                for blockID in exitChange.finishedBlockIDs {
                    self.ensureBlockView(for: blockID, in: tab)
                    self.updateBlockViewNow(for: blockID, in: tab)
                }
                self.stopRunningElapsedUpdates(for: tab)
                self.updateTabTitleForDirectory(tab)
                self.setTerminalControl(false, in: tab)
                self.updateCommandBarVisibility(for: tab)
            }
        }
    }

    private func finishHistoryReplay(in tab: TerminalTab) {
        tab.commandLifecycle.apply(.finishHistoryReplay)
        guard !tab.hasExited else { return }
        if !isCommandRunning(in: tab) {
            updateCommandBarDirectoryStatus(for: tab, forceRefresh: true)
            updateCommandBarVisibility(for: tab)
            updateTabTitleForDirectory(tab)
            scrollToBottom(tab)
            focusInput(for: tab)
            runInitialCommandIfNeeded(in: tab)
        }
    }

    private func configureInterruptHandling(for tab: TerminalTab) {
        tab.ptyPassthroughView.onInterrupt = { [weak self, weak tab] in
            guard let self, let tab else { return }
            tab.outputProcessor.prioritizeNextOutputForInput()
            self.interruptCommand(in: tab)
        }
        tab.session.onInterruptReconciled = { [weak tab] in
            guard let tab,
                  tab.interruptedBlockID == (tab.activeBlockID ?? tab.pendingBlockID)
            else {
                return
            }
            tab.outputProcessor.enqueueShellOutput("\u{1B}]133;D;130\u{7}")
        }
    }

    private func startShell(
        for tab: TerminalTab,
        workingDirectory: URL,
        shellPath: String? = nil
    ) {
        let isRemoteSession = tab.sessionRef.location != .local
        let isSSHSession: Bool
        if case .sshHost = tab.sessionRef.location {
            isSSHSession = true
        } else {
            isSSHSession = false
        }

        let shell = shellPath ?? (isRemoteSession
            ? "/bin/bash"
            : ProcessInfo.processInfo.environment["SHELL"].flatMap {
                FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil
            } ?? "/bin/zsh")

        var env: [String: String] = isRemoteSession
            ? [:]
            : Self.inheritedShellEnvironment(ProcessInfo.processInfo.environment)
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "dev.mxcl.portal"
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        env["TERM"] = "xterm-256color"
        env["TERM_PROGRAM"] = "Portal"
        env["TERM_PROGRAM_VERSION"] = appVersion
        env["LC_TERMINAL"] = "Portal"
        env["LC_TERMINAL_VERSION"] = appVersion
        env["__CFBundleIdentifier"] = bundleIdentifier
        env["PORTAL"] = "1"
        env["PROMPT"] = ""
        env["RPROMPT"] = ""

        let initScript = """
            export PORTAL=1
            export TERM=xterm-256color
            export TERM_PROGRAM=Portal
            export TERM_PROGRAM_VERSION=\(shellQuote(appVersion))
            export LC_TERMINAL=Portal
            export LC_TERMINAL_VERSION=\(shellQuote(appVersion))
            export __CFBundleIdentifier=\(shellQuote(bundleIdentifier))
            \(isSSHSession ? Self.remoteCodeFunctionScript : "")
            cd \(shellQuote(workingDirectory.path))
            \(PortalCommandEnvelope.inputSetupScript)
            PROMPT=''
            RPROMPT=''
            setopt no_prompt_cr 2>/dev/null || true
            printf '\\033]133;R;%s\\a' "$(pwd | base64)"

            """

        let initializingSessionRef = tab.sessionRef
        tab.session.onReady = { [weak self, weak tab] created in
            guard let self, let tab, tab.sessionRef == initializingSessionRef else { return }
            guard created else {
                tab.commandLifecycle.apply(.markNeedsShellInputReset)
                self.finishHistoryReplay(in: tab)
                return
            }
            self.setCommandBarStatusText("Starting shell...", in: tab)
            tab.commandLifecycle.apply(.beginShellInitialization)
            tab.pendingShellInitialization = initScript
            tab.session.write(PortalCommandEnvelope.shellBootstrapScript, suppressEcho: true)
        }

        let startedSessionRef = tab.sessionRef
        tab.session.start(shellPath: shell, environment: env, workingDirectory: workingDirectory) { [weak self, weak tab] result in
            guard let self, let tab, tab.sessionRef == startedSessionRef else { return }
            switch result {
            case .success:
                self.resizePtyToViewport(for: tab)
            case .failure(let error):
                self.setCommandBarStatusText("Failed to start shell: \(error.localizedDescription)", in: tab)
            }
        }
    }

    private enum CompletionRequestMode {
        case explicit
        case rightArrow
        case automatic
        case filtering
        case continuation
        case history
    }

    private func shouldStartAutomaticCompletion(in textView: NSTextView) -> Bool {
        let selectedRange = textView.selectedRange()
        guard selectedRange.length == 0 else { return false }

        let parsed = ShellCompletionParser.parse(input: textView.string, cursorOffset: selectedRange.location)
        guard parsed.commandTokenIndex != nil else { return false }

        if parsed.isCompletingCommand {
            return selectedRange.location == (textView.string as NSString).length
                && selectedRange.location >= 2
        }

        let prefix = (textView.string as NSString).substring(to: selectedRange.location)
        guard let lastCharacter = prefix.last else { return false }
        return lastCharacter.isWhitespace || !parsed.currentTokenText.isEmpty
    }

    private func requestCompletion(in tab: TerminalTab, mode: CompletionRequestMode) {
        guard tab.isShellReady, !tab.isReplayingHistory, !tab.isTerminalControlActive else { return }
        let selectedRange = tab.inputView.selectedRange()
        guard selectedRange.length == 0 else { return }

        completionRequestSerial += 1
        let serial = completionRequestSerial
        completionCancellation?.cancel()
        let cancellation = CompletionCancellation()
        completionCancellation = cancellation
        beginPendingCompletion(in: tab, mode: mode)
        var environment: [String: String]
        switch tab.sessionRef.location {
        case .local:
            environment = ProcessInfo.processInfo.environment
        case .sshHost:
            environment = [:]
        }
        environment["PWD"] = tab.currentCwd
        environment["SHELL"] = environment["SHELL"] ?? "/bin/zsh"
        let request = CompletionRequest(
            input: tab.inputView.string,
            cursorOffset: selectedRange.location,
            cwd: tab.currentCwd,
            shellPath: environment["SHELL"] ?? "/bin/zsh",
            environment: environment,
            location: tab.sessionRef.location,
            limit: 256,
            cancellation: cancellation,
            includesHistory: mode == .history ||
                (mode == .explicit && tab.inputView.string.isEmpty) ||
                (tab.inputView.string as NSString).length >= 2,
            historyOnly: mode == .history
        )

        completionQueue.async { [weak self, weak tab] in
            guard let self, !cancellation.isCancelled else { return }
            let result = self.completionEngine.completions(for: request)
            guard !cancellation.isCancelled else { return }
            DispatchQueue.main.async { [weak self, weak tab] in
                guard let self, let tab else { return }
                guard self.activeTabID == tab.id,
                      serial == self.completionRequestSerial else {
                    if self.deferredCompletionAcceptanceSerial == serial {
                        self.deferredCompletionAcceptanceSerial = nil
                    }
                    if serial == self.completionRequestSerial {
                        self.clearPendingCompletionIndicator()
                    }
                    return
                }
                if self.completionCancellation === cancellation {
                    self.completionCancellation = nil
                }
                let shouldAcceptAfterUpdate = self.deferredCompletionAcceptanceSerial == serial
                if shouldAcceptAfterUpdate {
                    self.deferredCompletionAcceptanceSerial = nil
                }
                self.clearPendingCompletionIndicator()
                self.handleCompletionResult(result, in: tab, mode: mode)
                if shouldAcceptAfterUpdate, self.completionPopup.isShown {
                    self.completeFromPopup(in: tab, continuingDirectories: true)
                }
            }
        }
    }

    private func handleCompletionResult(_ result: CompletionResult, in tab: TerminalTab, mode: CompletionRequestMode) {
        guard !result.suggestions.isEmpty else {
            dismissCompletion()
            guard mode == .explicit || mode == .rightArrow else { return }
            if result.canInsertCommandSeparator {
                let cursor = tab.inputView.selectedRange().location
                replace(range: NSRange(location: cursor, length: 0), with: " ", in: tab)
                requestCompletion(in: tab, mode: .continuation)
            } else {
                NSSound.beep()
            }
            return
        }

        activeCompletionRange = result.replacementRange
        activeCompletionCommonPrefix = result.commonPrefix
        activeCompletionMode = mode
        canInsertCommandSeparator = result.canInsertCommandSeparator
        if mode == .explicit,
           let prefix = result.commonPrefix,
           let existing = substring(in: tab.inputView.string, range: result.replacementRange),
           prefix.utf16.count > existing.utf16.count {
            replace(range: result.replacementRange, with: prefix, in: tab)
            activeCompletionRange = NSRange(location: result.replacementRange.location, length: prefix.utf16.count)
            updateCompletionAnchor(for: tab)
            if shouldContinueCompletion(afterInserting: prefix, from: result) {
                requestCompletion(in: tab, mode: .continuation)
                return
            }
        }

        if mode == .explicit,
           result.suggestions.count == 1,
           let suggestion = result.suggestions.first {
            let shouldContinue = shouldContinueCompletion(afterApplying: suggestion)
            applyCompletion(suggestion, in: tab, dismissAfterApplying: !shouldContinue)
            if shouldContinue {
                requestCompletion(in: tab, mode: .continuation)
            }
            return
        }

        let anchor = completionAnchorRect(for: tab.inputView, in: tab.commandBarView)
        completionPopup.show(
            suggestions: result.suggestions,
            relativeTo: anchor,
            of: tab.commandBarView
        )
        assert(completionPopup.selectedSuggestion == nil)
    }

    private func insertSharedCompletionPrefixIfAvailable(in tab: TerminalTab) -> Bool {
        guard let range = activeCompletionRange,
              let prefix = activeCompletionCommonPrefix,
              let existing = substring(in: tab.inputView.string, range: range),
              prefix.utf16.count > existing.utf16.count
        else {
            return false
        }

        guard existing.isEmpty ||
            prefix.range(of: existing, options: [.caseInsensitive, .anchored]) != nil
        else {
            return false
        }

        tab.inputView.clearMutedCompletionPreview()
        replace(range: range, with: prefix, in: tab)
        activeCompletionRange = NSRange(location: range.location, length: prefix.utf16.count)
        updateCompletionAnchor(for: tab)
        if prefix.hasSuffix("/") {
            completionPopup.clearSelection()
            requestCompletion(in: tab, mode: .continuation)
        }
        if let suggestion = completionPopup.selectedSuggestion {
            renderCompletionPreview(suggestion, in: tab)
        }
        return true
    }

    private func deferCompletionAcceptanceUntilPendingRequestCompletes(in tab: TerminalTab) -> Bool {
        guard pendingCompletionRequestTabID == tab.id else { return false }
        tab.completionPendingLine.isHidden = false
        deferredCompletionAcceptanceSerial = completionRequestSerial
        return true
    }

    private func completeFromPopup(in tab: TerminalTab, continuingDirectories: Bool = false) {
        if consumeOnlyCompletion(in: tab) {
            return
        }
        if completionPopup.selectedSuggestion == nil {
            _ = completionPopup.selectNext()
        }
        if insertSharedCompletionPrefixIfAvailable(in: tab) {
            return
        }
        acceptSelectedCompletion(in: tab, continuingDirectories: continuingDirectories)
    }

    private func consumeOnlyCompletion(in tab: TerminalTab) -> Bool {
        guard completionPopup.selectedSuggestion == nil,
              completionPopup.hasSingleSuggestion
        else {
            return false
        }
        _ = completionPopup.selectNext()
        acceptSelectedCompletion(in: tab, continuingDirectories: true)
        return true
    }

    private func acceptSelectedCompletion(in tab: TerminalTab, continuingDirectories: Bool = false) {
        guard let suggestion = completionPopup.selectedSuggestion else {
            dismissCompletion()
            return
        }
        let shouldContinue = continuingDirectories && shouldContinueCompletion(afterApplying: suggestion)
        applyCompletion(suggestion, in: tab, dismissAfterApplying: !shouldContinue)
        if shouldContinue {
            requestCompletion(in: tab, mode: .continuation)
        }
    }

    private var shellLineResetSequence: String {
        "\u{15}"
    }

    private func shellInputResetPrefixIfNeeded(in tab: TerminalTab) -> String {
        tab.commandLifecycle.apply(.consumeShellInputReset).didConsumeShellInputReset
            ? shellLineResetSequence
            : ""
    }

    private func previewCompletionSelection(_ suggestion: CompletionSuggestion) {
        guard let tab = activeTab else { return }
        renderCompletionPreview(suggestion, in: tab)
    }

    private func acceptCompletionSelection(_ suggestion: CompletionSuggestion) {
        guard let tab = activeTab else {
            dismissCompletion()
            return
        }
        renderCompletionPreview(suggestion, in: tab)
        applyCompletion(suggestion, in: tab, dismissAfterApplying: !shouldContinueCompletion(afterApplying: suggestion))
        if shouldContinueCompletion(afterApplying: suggestion) {
            requestCompletion(in: tab, mode: .continuation)
        }
    }

    private func applyCompletion(
        _ suggestion: CompletionSuggestion,
        in tab: TerminalTab,
        dismissAfterApplying: Bool = true
    ) {
        tab.inputView.clearMutedCompletionPreview()
        guard let range = Self.completionReplacementRange(
            for: suggestion,
            inputLength: (tab.inputView.string as NSString).length,
            fallback: activeCompletionRange
        ) else { return }
        replace(range: range, with: suggestion.insertText, in: tab)
        if dismissAfterApplying {
            dismissCompletion()
        } else {
            updateCompletionAnchor(for: tab)
        }
    }

    private func renderCompletionPreview(_ suggestion: CompletionSuggestion, in tab: TerminalTab) {
        guard let replacementRange = Self.completionReplacementRange(
            for: suggestion,
            inputLength: (tab.inputView.string as NSString).length,
            fallback: activeCompletionRange
        ) else {
            tab.inputView.clearMutedCompletionPreview()
            return
        }
        tab.inputView.renderCompletionPreview(suggestion, replacementRange: replacementRange)
    }

    private static func completionReplacementRange(
        for suggestion: CompletionSuggestion,
        inputLength: Int,
        fallback: NSRange?
    ) -> NSRange? {
        suggestion.kind == .history
            ? NSRange(location: 0, length: inputLength)
            : suggestion.replacementRange ?? fallback
    }

    static func historyCompletionReplacementRangeSelfTest() -> Bool {
        let original = "./scripts/de"
        let expanded = "./scripts/deploy-www.sh "
        let suggestion = CompletionSuggestion(
            displayText: "./scripts/deploy-www.sh --static-only",
            insertText: "./scripts/deploy-www.sh --static-only",
            description: nil,
            kind: .history,
            priority: 0,
            source: "self-test",
            replacementRange: NSRange(location: 0, length: original.utf16.count)
        )
        return completionReplacementRange(
            for: suggestion,
            inputLength: expanded.utf16.count,
            fallback: suggestion.replacementRange
        ) == NSRange(location: 0, length: expanded.utf16.count)
    }

    private func shouldContinueCompletion(afterApplying suggestion: CompletionSuggestion) -> Bool {
        suggestion.kind == .folder ||
            suggestion.insertText.hasSuffix("/") ||
            (suggestion.kind == .command && suggestion.insertText.last?.isWhitespace == true)
    }

    private func shouldContinueCompletion(afterInserting value: String, from result: CompletionResult) -> Bool {
        guard value.hasSuffix("/") else { return false }
        return result.suggestions.contains { suggestion in
            suggestion.kind == .file || suggestion.kind == .folder
        }
    }

    private func replace(range: NSRange, with value: String, in tab: TerminalTab) {
        let text = tab.inputView.string as NSString
        guard range.location >= 0,
              range.location + range.length <= text.length
        else {
            return
        }
        let updated = text.replacingCharacters(in: range, with: value)
        isApplyingCompletion = true
        tab.inputView.string = updated
        tab.inputView.normalizePlainTextStorage()
        let cursor = range.location + (value as NSString).length
        tab.inputView.setSelectedRange(NSRange(location: cursor, length: 0))
        updateCommandInputHeight(for: tab)
        tab.inputView.scrollRangeToVisible(NSRange(location: cursor, length: 0))
        isApplyingCompletion = false
    }

    private func updateCompletionAnchorForActiveTab() {
        guard let tab = activeTab else { return }
        updateCompletionAnchor(for: tab)
    }

    private func updateCompletionAnchor(for tab: TerminalTab) {
        guard completionPopup.isShown else { return }
        guard tab.inputView.selectedRange().length == 0 else {
            dismissCompletion()
            return
        }

        let anchor = completionAnchorRect(for: tab.inputView, in: tab.commandBarView)
        completionPopup.reposition(relativeTo: anchor, of: tab.commandBarView)
    }

    private func dismissCompletion() {
        if let tab = activeTab {
            tab.inputView.clearMutedCompletionPreview()
        }
        clearPendingCompletionIndicator()
        activeCompletionRange = nil
        activeCompletionCommonPrefix = nil
        activeCompletionMode = nil
        canInsertCommandSeparator = false
        deferredCompletionAcceptanceSerial = nil
        completionPopup.dismiss()
        completionCancellation?.cancel()
        completionCancellation = nil
        completionRequestSerial += 1
    }

    private func beginPendingCompletion(in tab: TerminalTab, mode: CompletionRequestMode) {
        clearPendingCompletionIndicator()
        pendingCompletionRequestTabID = tab.id
        tab.completionPendingLine.isHidden = mode != .explicit
    }

    private func clearPendingCompletionIndicator() {
        guard let tabID = pendingCompletionRequestTabID else { return }
        tabs.first { $0.id == tabID }?.completionPendingLine.isHidden = true
        pendingCompletionRequestTabID = nil
    }

    private func substring(in value: String, range: NSRange) -> String? {
        let text = value as NSString
        guard range.location >= 0,
              range.location + range.length <= text.length
        else {
            return nil
        }
        return text.substring(with: range)
    }

    private func completionAnchorRect(for textView: NSTextView, in containerView: NSView) -> NSRect {
        func boundedAnchorRect(_ rect: NSRect) -> NSRect {
            let width = max(1, rect.width)
            let height = max(1, rect.height)
            let minX = containerView.bounds.minX
            let maxX = max(minX, containerView.bounds.maxX - width)
            let minY = containerView.bounds.minY
            let maxY = max(minY, containerView.bounds.maxY - height)
            let x = min(max(rect.minX, minX), maxX)
            let y = min(max(rect.minY, minY), maxY)
            return NSRect(x: x, y: y, width: width, height: height)
        }

        func rectInTextViewCoordinates(from textContainerRect: NSRect) -> NSRect {
            let origin = textView.textContainerOrigin
            return NSRect(
                x: origin.x + textContainerRect.minX,
                y: origin.y + textContainerRect.minY,
                width: textContainerRect.width,
                height: textContainerRect.height
            )
        }

        let textViewRect = textView.convert(textView.bounds, to: containerView)
        let lineHeight = textView.font.map { textView.layoutManager?.defaultLineHeight(for: $0) ?? $0.boundingRectForFont.height } ?? 16
        let fallbackRect = NSRect(
            x: textViewRect.minX + textView.textContainerInset.width,
            y: textViewRect.minY + textView.textContainerInset.height,
            width: 1,
            height: lineHeight
        )

        let selectedRange = textView.selectedRange()
        let textLength = (textView.string as NSString).length
        let cursorLocation = min(max(0, selectedRange.location), textLength)

        if let window = textView.window {
            var actualRange = NSRange(location: NSNotFound, length: 0)
            let screenRect = textView.firstRect(
                forCharacterRange: NSRange(location: cursorLocation, length: 0),
                actualRange: &actualRange
            )
            if !screenRect.isEmpty, !screenRect.origin.x.isNaN, !screenRect.origin.y.isNaN {
                let windowRect = window.convertFromScreen(screenRect)
                let containerRect = containerView.convert(windowRect, from: nil)
                return boundedAnchorRect(NSRect(
                    x: containerRect.minX,
                    y: containerRect.minY,
                    width: 1,
                    height: max(lineHeight, containerRect.height)
                ))
            }
        }

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else {
            return boundedAnchorRect(fallbackRect)
        }

        layoutManager.ensureLayout(for: textContainer)

        guard textLength > 0, layoutManager.numberOfGlyphs > 0 else {
            return boundedAnchorRect(fallbackRect)
        }

        let characterLocation = cursorLocation < textLength ? cursorLocation : textLength - 1
        let glyphIndex = min(
            layoutManager.glyphIndexForCharacter(at: characterLocation),
            max(0, layoutManager.numberOfGlyphs - 1)
        )
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        )
        let caretX = cursorLocation < textLength ? glyphRect.minX : glyphRect.maxX
        let textCaretRect = rectInTextViewCoordinates(from: NSRect(
            x: caretX,
            y: glyphRect.minY,
            width: 1,
            height: max(lineHeight, glyphRect.height)
        ))
        return boundedAnchorRect(textView.convert(textCaretRect, to: containerView))
    }

    private func submitCommand(
        in tab: TerminalTab,
        exitsShellAfterCompletion: Bool = false
    ) {
        guard tab.isShellReady, !tab.isReplayingHistory else { return }
        dismissCompletion()
        hideSessionPicker(for: tab)
        // Submit the complete script so the shell owns quoting and line continuations.
        let rawCommand = tab.inputView.string
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            submitEmptyCommand(rawCommand, in: tab)
            return
        }
        let submission = tab.commandLifecycle.apply(.submit(
            command: command,
            cwd: tab.currentCwd,
            at: Date()
        ))
        guard let blockID = submission.addedBlockIDs.first,
              let block = tab.blocks.first(where: { $0.id == blockID })
        else { return }
        if rawCommand.first == " " {
            tab.hostHistoryOptOutBlockIDs.insert(blockID)
        }
        clearCommandInput(in: tab)
        let usesPagerScreenRendering = usesPagerScreenRendering(for: command)
        updateTabTitle(titleForCommand(command), detail: command, in: tab)

        persistSessionState()
        tab.outputProcessor.resetForCommand(
            blockID: block.id,
            cwd: block.cwd,
            usesPagerScreenRendering: usesPagerScreenRendering
        )
        addBlockView(block, to: tab)
        updateCommandBarVisibility(for: tab)
        resizePtyToViewport(for: tab)
        scrollToBottomNow(tab)
        startRunningElapsedUpdates(for: tab)

        let script = shellInputResetPrefixIfNeeded(in: tab) + PortalCommandEnvelope.shellScript(
            for: command,
            exitsShellAfterCompletion: exitsShellAfterCompletion
        )
        tab.session.write(script, suppressEcho: true)
        updatePassthroughVisibility(for: tab)
        focusInput(for: tab)
    }

    private func submitEmptyCommand(_ rawCommand: String, in tab: TerminalTab) {
        hideSessionPicker(for: tab)
        clearCommandInput(in: tab)
        let submission = tab.commandLifecycle.apply(.submitEmpty(cwd: tab.currentCwd, at: Date()))
        guard let blockID = submission.addedBlockIDs.first,
              let block = tab.blocks.first(where: { $0.id == blockID })
        else { return }
        addBlockView(block, to: tab)
        updateCommandBarVisibility(for: tab)
        tab.session.write(shellLineResetSequence + shellInputResetPrefixIfNeeded(in: tab) + rawCommand + "\n", suppressEcho: true)
        updateCommandBarDirectoryStatus(for: tab, forceRefresh: true)
        focusInput(for: tab)
    }

    private func interruptCommand(in tab: TerminalTab) {
        guard isCommandRunning(in: tab) else { return }
        tab.interruptedBlockID = tab.activeBlockID ?? tab.pendingBlockID
        tab.commandLifecycle.apply(.interruptRequested)
        tab.session.sendInterrupt()
    }

    private func showPreviousCommand(in tab: TerminalTab) -> Bool {
        let change = tab.commandLifecycle.apply(.previousHistory(draft: tab.inputView.string))
        guard let input = change.selectedHistoryInput else { return false }
        setInput(input, in: tab)
        return true
    }

    private func showNextCommand(in tab: TerminalTab) -> Bool {
        let change = tab.commandLifecycle.apply(.nextHistory)
        guard let input = change.selectedHistoryInput else { return false }
        setInput(input, in: tab)
        return true
    }

    private func setInput(_ value: String, in tab: TerminalTab) {
        tab.inputView.clearMutedCompletionPreview()
        tab.inputView.string = value
        tab.inputView.normalizePlainTextStorage()
        let location = (value as NSString).length
        tab.inputView.setSelectedRange(NSRange(location: location, length: 0))
        updateCommandInputHeight(for: tab)
        tab.inputView.scrollRangeToVisible(NSRange(location: location, length: 0))
    }

    private func updateCommandInputHeight(for tab: TerminalTab) {
        guard let constraint = tab.commandInputHeightConstraint,
              let layoutManager = tab.inputView.layoutManager,
              let textContainer = tab.inputView.textContainer
        else {
            return
        }

        layoutManager.ensureLayout(for: textContainer)
        let contentHeight = layoutManager.usedRect(for: textContainer).height
        let lineHeight = tab.inputView.font.map {
            layoutManager.defaultLineHeight(for: $0)
        } ?? 16
        let height = CommandInputTextView.visibleHeight(
            contentHeight: contentHeight,
            lineHeight: lineHeight,
            verticalInset: tab.inputView.textContainerInset.height
        )
        guard constraint.constant != height else { return }
        constraint.constant = height
        tab.rootView.layoutSubtreeIfNeeded()
    }

    private func handleOutputProcessorEvent(_ event: TerminalOutputProcessor.Event, in tab: TerminalTab) {
        switch event {
        case .snapshot(let snapshot):
            applyOutputSnapshot(snapshot, in: tab)
        case .marker(let marker, let isReplay):
            handleMarker(marker, isReplay: isReplay, in: tab)
        case .replayCommandStarted(let blockID, let command):
            beginReplayedCommandBlock(blockID: blockID, command: command, in: tab)
        }
    }

    private func beginReplayedCommandBlock(blockID: UUID, command: String, in tab: TerminalTab) {
        let change = tab.commandLifecycle.apply(.replayCommandStarted(
            blockID: blockID,
            command: command,
            at: Date()
        ))
        for finishedBlockID in change.finishedBlockIDs {
            ensureBlockView(for: finishedBlockID, in: tab)
            updateBlockViewNow(for: finishedBlockID, in: tab)
        }
        guard change.addedBlockIDs.contains(blockID),
              let block = tab.blocks.first(where: { $0.id == blockID })
        else { return }
        if !tab.isReplayingHistory {
            hideSessionPicker(for: tab)
        }
        if !change.finishedBlockIDs.isEmpty {
            stopRunningElapsedUpdates(for: tab)
        }
        addBlockView(block, to: tab)
        updateTabTitle(command.isEmpty ? tab.title : titleForCommand(command), detail: command, in: tab)
        updateCommandBarVisibility(for: tab)
    }

    private func applyOutputSnapshot(_ snapshot: TerminalOutputProcessor.Snapshot, in tab: TerminalTab) {
        tab.mouseTrackingMode = snapshot.mouseTrackingMode
        tab.usesSGRMouseMode = snapshot.usesSGRMouseMode
        let change = tab.commandLifecycle.apply(.output(
            blockID: snapshot.blockID,
            plainText: snapshot.plainText,
            attributedText: snapshot.attributedText,
            isAlternateScreenActive: snapshot.isAlternateScreenActive,
            isApplicationCursorModeActive: snapshot.isApplicationCursorModeActive
        ))
        guard change.updatedBlockIDs.contains(snapshot.blockID) else { return }

        ensureBlockView(for: snapshot.blockID, in: tab)
        scheduleBlockViewUpdate(for: snapshot.blockID, in: tab)
        if tab.isFindMode {
            updateFindResults(in: tab, bounce: false)
        }
        if change.didChangeTerminalMode {
            refreshTerminalControl(in: tab)
        }
    }

    private func handleMarker(_ marker: PortalMarker, isReplay: Bool, in tab: TerminalTab) {
        switch marker.kind {
        case .commandStarted, .commandFinished:
            let oscPayload = "133;\(marker.rawValue)"
            guard oscPayload.hasPrefix("133;") else {
                return
            }
        default:
            break
        }
        switch marker.kind {
        case .shellReady(let cwd):
            if let script = tab.pendingShellInitialization {
                tab.pendingShellInitialization = nil
                tab.session.write(script, suppressEcho: true)
                return
            }
            tab.commandLifecycle.apply(.shellReady(cwd: cwd))
            updateCommandBarDirectoryStatus(for: tab, forceRefresh: true)
            refreshGitTreeIfVisible(for: tab)
            updateCommandBarVisibility(for: tab)
            updateTabTitleForDirectory(tab)
            persistSessionState()
            runInitialCommandIfNeeded(in: tab)
        case .commandStarted:
            tab.mouseTrackingMode = nil
            tab.usesSGRMouseMode = false
            tab.commandLifecycle.apply(.commandStarted)
        case .cwdChanged(let cwd):
            if let cwd {
                tab.commandLifecycle.apply(.cwdChanged(cwd))
                updateCommandBarDirectoryStatus(for: tab)
                refreshGitTreeIfVisible(for: tab)
            }
            persistSessionState()
        case .openRemoteCode(let payload):
            if !isReplay {
                openRemoteCode(payload: payload, in: tab)
            }
        case .commandFinished(let status):
            let wasAtBottom = tab.isScrolledToBottom
            tab.mouseTrackingMode = nil
            tab.usesSGRMouseMode = false
            tab.interruptedBlockID = nil
            let finishedBlock = (tab.activeBlockID ?? tab.pendingBlockID).flatMap { blockID in
                tab.blocks.first(where: { $0.id == blockID })
            }
            let change = tab.commandLifecycle.apply(.commandFinished(
                status: status,
                isReplay: isReplay,
                at: Date()
            ))
            for blockID in change.finishedBlockIDs {
                let optedOut = tab.hostHistoryOptOutBlockIDs.remove(blockID) != nil
                ensureBlockView(for: blockID, in: tab)
                updateBlockViewNow(for: blockID, in: tab)
                if status == 0,
                   !isReplay,
                   !optedOut,
                   let block = finishedBlock,
                   block.id == blockID {
                    recordSuccessfulCommand(block.command, cwd: block.cwd, in: tab)
                }
            }
            if !isReplay && !change.finishedBlockIDs.isEmpty {
                tab.hasUnviewedCompletion = !(isTerminalVisible && activeTabID == tab.id && view.window?.isKeyWindow == true)
            }
            stopRunningElapsedUpdates(for: tab)
            setTerminalControl(false, in: tab)
            updateCommandBarDirectoryStatus(for: tab, forceRefresh: true)
            refreshGitTreeIfVisible(for: tab)
            updateCommandBarVisibility(for: tab)
            updateTabTitleForDirectory(tab)
            persistSessionState()
            if wasAtBottom { scrollToBottomNow(tab) }
            focusInput(for: tab)
            runInitialCommandIfNeeded(in: tab)
        case .unknown(let code, let payload):
            guard code == "I",
                  !isReplay,
                  let data = Data(base64Encoded: payload),
                  let input = String(data: data, encoding: .utf8),
                  !input.isEmpty
            else {
                break
            }
            setInput(tab.inputView.string + input, in: tab)
        }
    }

    private func recordSuccessfulCommand(_ command: String, cwd: String, in tab: TerminalTab) {
        let location = tab.sessionRef.location
        completionQueue.async { [weak self] in
            self?.completionEngine.recordSuccessfulCommand(
                command,
                cwd: cwd,
                location: location
            )
        }
    }

    static var remoteCodeFunctionScript: String {
        """
        code() {
          if [ "$#" -eq 0 ]; then
            printf 'usage: code PATH\\n' >&2
            return 2
          fi
          local __portal_target="$1" __portal_kind __portal_dir __portal_name __portal_abs
          if [ -d "$__portal_target" ]; then
            __portal_kind=folder
            __portal_abs="$(cd "$__portal_target" 2>/dev/null && pwd -P)" || return 1
          else
            __portal_kind=file
            case "$__portal_target" in
              */*) __portal_dir="${__portal_target%/*}"; __portal_name="${__portal_target##*/}" ;;
              *) __portal_dir=.; __portal_name="$__portal_target" ;;
            esac
            [ -n "$__portal_dir" ] || __portal_dir=/
            __portal_abs="$(cd "$__portal_dir" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$__portal_name")" || return 1
          fi
          printf '\\033]133;O;%s;%s\\a' "$__portal_kind" "$(printf '%s' "$__portal_abs" | base64 | tr -d '\\n')"
        }
        """
    }

    private func openRemoteCode(payload: String, in tab: TerminalTab) {
        let parts = payload.split(separator: ";", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let remotePath = decodeBase64(parts[1]).map(cleanRemoteCodePath),
              let host = sshHost(for: tab.sessionRef.location),
              let uri = vscodeRemoteURI(kind: parts[0], host: host, path: remotePath)
        else {
            return
        }

        let process = Process()
        let codePath = codeExecutablePath()
        process.executableURL = URL(fileURLWithPath: codePath)
        let arguments = [parts[0] == "file" ? "--file-uri" : "--folder-uri", uri]
        process.arguments = codePath == "/usr/bin/env" ? ["code"] + arguments : arguments
        try? process.run()
    }

    private func cleanRemoteCodePath(_ path: String) -> String {
        var path = path
        while path.hasPrefix("\u{1B}]133;"),
              let end = path.firstIndex(of: "\u{7}") {
            path.removeSubrange(...end)
        }
        return path
    }

    private func sshHost(for location: SessionLocation) -> SSHHostRecord? {
        guard case .sshHost(let hostID) = location else { return nil }
        return PtySession.loadSSHHosts().hosts.first { $0.id == hostID }
    }

    private func vscodeRemoteURI(kind: String, host: SSHHostRecord, path: String) -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "%?#")
        guard kind == "file" || kind == "folder",
              let encodedPath = path.addingPercentEncoding(withAllowedCharacters: allowed)
        else {
            return nil
        }
        let absolutePath = encodedPath.hasPrefix("/") ? encodedPath : "/" + encodedPath
        let hostname = host.hostname.isEmpty ? host.alias : host.hostname
        return "vscode-remote://ssh-remote+\(hostname)\(absolutePath)"
    }

    private func codeExecutablePath() -> String {
        for path in [
            "/usr/local/bin/code",
            "/opt/homebrew/bin/code",
            "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
        ] where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/usr/bin/env"
    }

    private func usesPagerScreenRendering(for command: String) -> Bool {
        guard let name = commandName(from: command) else { return false }
        return ["less", "man", "more", "most"].contains(name)
    }

    private static func inheritedShellEnvironment(_ environment: [String: String]) -> [String: String] {
        var environment = environment
        let pager = environment["PAGER"].flatMap { $0 == "cat" ? nil : $0 } ?? "less"
        if environment["PAGER"] == nil || environment["PAGER"] == "cat" {
            environment["PAGER"] = pager
        }
        if environment["GIT_PAGER"] == nil || environment["GIT_PAGER"] == "cat" {
            environment["GIT_PAGER"] = pager
        }
        return environment
    }

    private func updateTabTitle(_ title: String, detail: String? = nil, in tab: TerminalTab) {
        let fallback = titleForDirectory(tab.currentCwd)
        let normalizedTitle = singleLineTitle(standardTabTitle(title, in: tab))
        let standardTitle = normalizedTitle.isEmpty ? fallback : normalizedTitle
        let displayTitle = displayTabTitle(standardTitle, in: tab)
        tab.title = displayTitle
        if standalone {
            view.window?.title = displayTitle
            view.window?.tab.toolTip = detail ?? tab.currentCwd
        }
    }

    private func displayTabTitle(_ title: String, in tab: TerminalTab) -> String {
        guard let hostname = hostname(for: tab.sessionRef) else {
            return title
        }
        return "\(hostname):\(title)"
    }

    private func standardTabTitle(_ title: String, in tab: TerminalTab) -> String {
        guard let hostname = hostname(for: tab.sessionRef) else {
            return title
        }
        let prefix = "\(hostname):"
        guard title.hasPrefix(prefix) else {
            return title
        }
        return String(title.dropFirst(prefix.count))
    }

    private func updateTabTitleForDirectory(_ tab: TerminalTab) {
        updateTabTitle(
            titleForDirectory(tab.currentCwd),
            detail: detailForDirectory(tab.currentCwd),
            in: tab
        )
    }

    private func titleForDirectory(_ cwd: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (cwd as NSString).standardizingPath
        if let gitRoot = gitStateProvider.repositoryRoot(
            forDirectory: URL(fileURLWithPath: path, isDirectory: true)
        ) {
            return titleForGitDirectory(path, repositoryRoot: gitRoot)
        }
        if path == home {
            return "~"
        }
        if path == "/" {
            return "/"
        }

        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func titleForGitDirectory(_ cwd: String, repositoryRoot: String) -> String {
        let rootPath = (repositoryRoot as NSString).standardizingPath
        let rootName = (rootPath as NSString).lastPathComponent
        guard !rootName.isEmpty else { return titleForNonGitDirectory(cwd) }

        if cwd == rootPath {
            return rootName
        }
        if cwd.hasPrefix(rootPath + "/") {
            let relativePath = String(cwd.dropFirst(rootPath.count + 1))
            return relativePath.isEmpty ? rootName : "\(rootName)/\(relativePath)"
        }
        return titleForNonGitDirectory(cwd)
    }

    private func titleForNonGitDirectory(_ cwd: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if cwd == home {
            return "~"
        }
        if cwd == "/" {
            return "/"
        }

        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    private func detailForDirectory(_ cwd: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (cwd as NSString).standardizingPath
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    private func updateCommandBarDirectoryStatus(for tab: TerminalTab, forceRefresh: Bool = false) {
        guard !tab.isFindMode else { return }
        let cwd = tab.currentCwd
        let location = tab.sessionRef.location
        let directoryText = detailForDirectory(cwd)
        setCommandBarStatusText(directoryText, in: tab)

        gitStateQueue.async { [weak self, weak tab] in
            guard let self else { return }
            let gitSummary = self.gitStateProvider.summary(
                forDirectory: URL(fileURLWithPath: cwd, isDirectory: true),
                location: location,
                forceRefresh: forceRefresh
            )

            DispatchQueue.main.async { [weak tab] in
                guard let tab,
                      tab.currentCwd == cwd,
                      tab.isShellReady,
                      !tab.isFindMode
                else {
                    return
                }
                guard let gitSummary else {
                    self.setCommandBarStatusText(directoryText, in: tab)
                    return
                }
                tab.statusLabel.attributedStringValue = self.commandBarStatusText(
                    directoryText: directoryText,
                    gitSummary: gitSummary,
                    font: tab.statusLabel.font,
                    hostPrefix: self.hostname(for: tab.sessionRef)
                )
            }
        }
    }

    private func refreshVisibleCommandBarGitStatus() {
        guard let tab = activeTab else { return }
        refreshVisibleCommandBarGitStatus(for: tab)
    }

    private func refreshVisibleCommandBarGitStatus(for tab: TerminalTab) {
        guard tab.isShellReady, !tab.commandBarView.isHidden else { return }
        updateCommandBarDirectoryStatus(for: tab, forceRefresh: true)
    }

    private func updateGitRepositoryWatcher() {
        let url: URL?
        if let tab = activeTab, case .local = tab.sessionRef.location {
            url = URL(fileURLWithPath: tab.currentCwd, isDirectory: true)
        } else { url = nil }
        guard gitRepositoryWatchURL != url else { return }
        gitRepositoryWatchTask?.cancel()
        gitRepositoryWatcher = nil
        gitRepositoryWatchURL = url
        guard let url else { return }
        gitRepositoryWatchTask = Task { [weak self] in
            let paths = await Task.detached {
                (try? RepositoryWatcher.paths(for: url)) ?? [url.path]
            }.value
            guard !Task.isCancelled, let self, self.gitRepositoryWatchURL == url else { return }
            do {
                self.gitRepositoryWatcher = try RepositoryWatcher(paths: paths) { [weak self] in
                    self?.refreshGitTreeIfVisible()
                    self?.refreshVisibleCommandBarGitStatus()
                }
                self.refreshGitTreeIfVisible()
                self.refreshVisibleCommandBarGitStatus()
            } catch {
                self.gitTreeView.display(.message("Live Git tree updates unavailable: \(error.localizedDescription)"))
            }
        }
    }

    private func refreshGitTreeIfVisible(for tab: TerminalTab? = nil) {
        updateGitRepositoryWatcher()
        guard isGitTreeVisible,
              let tab = tab ?? activeTab,
              tab.id == activeTabID
        else {
            return
        }

        if isGitTreeRefreshPending { gitTreeRefreshAgain = true; return }
        let cwd = tab.currentCwd
        let location = tab.sessionRef.location
        guard case .local = location else {
            gitTreeView.display(Self.gitTreeContent(nil, location: location))
            return
        }

        isGitTreeRefreshPending = true
        gitStateQueue.async { [weak self, weak tab] in
            guard let self else { return }
            let tree = self.gitStateProvider.tree(
                forDirectory: URL(fileURLWithPath: cwd, isDirectory: true),
                location: location
            )
            DispatchQueue.main.async { [weak self, weak tab] in
                guard let self else { return }
                self.isGitTreeRefreshPending = false
                defer {
                    if self.gitTreeRefreshAgain {
                        self.gitTreeRefreshAgain = false
                        self.refreshGitTreeIfVisible()
                    }
                }
                guard let tab,
                      self.isGitTreeVisible,
                      tab.id == self.activeTabID,
                      tab.currentCwd == cwd
                else {
                    return
                }
                self.gitTreeView.display(Self.gitTreeContent(tree, location: location))
            }
        }
    }

    private static func gitTreeContent(
        _ tree: [GitDirectoryStateProvider.TreeRow]?,
        location: SessionLocation
    ) -> GitTreeContent {
        guard case .local = location else {
            return .message("Git tree is unavailable for remote tabs")
        }
        guard let tree else { return .message("Not a Git repository") }
        return tree.isEmpty ? .message("No commits yet") : .graph(tree)
    }

    private func setCommandBarStatusText(_ text: String, in tab: TerminalTab) {
        tab.statusLabel.attributedStringValue = commandBarStatusText(
            text,
            font: tab.statusLabel.font,
            hostPrefix: hostname(for: tab.sessionRef)
        )
    }

    private func commandBarStatusText(
        _ text: String,
        font: NSFont?,
        hostPrefix: String?
    ) -> NSAttributedString {
        let statusFont = font ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        let output = NSMutableAttributedString()
        output.append(NSAttributedString(
            string: text,
            attributes: [
                .font: statusFont,
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        ))
        appendCommandBarStatusHostSuffix(to: output, hostPrefix: hostPrefix)
        return output
    }

    private func commandBarStatusText(
        directoryText: String,
        gitSummary: GitDirectoryStateProvider.Summary,
        font: NSFont?,
        hostPrefix: String?
    ) -> NSAttributedString {
        let statusFont = font ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        let directoryAttributes: [NSAttributedString.Key: Any] = [
            .font: statusFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let gitAttributes: [NSAttributedString.Key: Any] = [
            .font: statusFont,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let output = NSMutableAttributedString(
            string: directoryText,
            attributes: directoryAttributes
        )
        let showsDiffLineStats = gitSummary.insertions > 0 || gitSummary.deletions > 0
        let gitState = if showsDiffLineStats {
            ""
        } else {
            " \(gitSummary.isDirty ? "dirty" : "clean")"
        }
        output.append(NSAttributedString(
            string: "  git \(gitSummary.branch)\(gitState)",
            attributes: gitAttributes
        ))
        if gitSummary.insertions > 0 {
            output.append(NSAttributedString(
                string: " +\(gitSummary.insertions)",
                attributes: [
                    .font: statusFont,
                    .foregroundColor: mutedGitStatusColor(.systemGreen)
                ]
            ))
        }
        if gitSummary.deletions > 0 {
            output.append(NSAttributedString(
                string: "\u{2009}-\(gitSummary.deletions)",
                attributes: [
                    .font: statusFont,
                    .foregroundColor: mutedGitStatusColor(.systemRed)
                ]
            ))
        }
        appendCommandBarStatusHostSuffix(to: output, hostPrefix: hostPrefix)
        return output
    }

    private func appendCommandBarStatusHostSuffix(
        to output: NSMutableAttributedString,
        hostPrefix: String?
    ) {
        guard let hostPrefix = hostPrefix?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hostPrefix.isEmpty
        else {
            return
        }

        output.append(NSAttributedString(string: "  "))
        output.append(hostPrefixAttributedString(hostPrefix, color: TahoeGlassPalette.titleTextActive))
    }

    private func clearCommandInput(in tab: TerminalTab) {
        guard !tab.isFindMode else { return }
        tab.inputView.clearMutedCompletionPreview()
        tab.inputView.string = ""
        tab.inputView.resetPlainTextAttributes()
        tab.inputView.isSelectable = true
        tab.inputView.isEditable = true
        updateCommandInputHeight(for: tab)
    }

    private func titleForCommand(_ command: String) -> String {
        singleLineTitle(command)
    }

    private func singleLineTitle(_ title: String) -> String {
        title
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func commandName(from command: String) -> String? {
        let wrappers = Set(["builtin", "command", "env", "exec", "noglob", "sudo"])
        for part in command.split(whereSeparator: { $0.isWhitespace }) {
            let token = String(part)
            if token.contains("="), !token.hasPrefix("./"), !token.hasPrefix("/") {
                continue
            }

            let name = URL(fileURLWithPath: token).lastPathComponent.lowercased()
            if wrappers.contains(name) {
                continue
            }
            return name
        }
        return nil
    }

    private func startRunningElapsedUpdates(for tab: TerminalTab) {
        stopRunningElapsedUpdates(for: tab)
        refreshRunningElapsedTime(in: tab)
    }

    private func stopRunningElapsedUpdates(for tab: TerminalTab) {
        tab.runningElapsedTimer?.invalidate()
        tab.runningElapsedTimer = nil
    }

    private func refreshRunningElapsedTime(in tab: TerminalTab) {
        let now = Date()
        guard let runningBlock = latestRunningBlock(in: tab) else {
            stopRunningElapsedUpdates(for: tab)
            return
        }

        tab.blockViews[runningBlock.id]?.update(with: runningBlock, now: now)

        let refreshInterval = displayRefreshInterval(for: tab)
        let interval = BlockView.liveDurationRefreshInterval(
            startedAt: runningBlock.startedAt,
            now: now,
            refreshInterval: refreshInterval
        )
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self, weak tab] timer in
            guard let self, let tab else {
                timer.invalidate()
                return
            }
            self.refreshRunningElapsedTime(in: tab)
        }
        tab.runningElapsedTimer = timer
    }

    private func displayRefreshInterval(for tab: TerminalTab) -> TimeInterval {
        let refreshRate = tab.rootView.window?.screen?.maximumFramesPerSecond
            ?? view.window?.screen?.maximumFramesPerSecond
            ?? NSScreen.main?.maximumFramesPerSecond
            ?? fallbackDisplayRefreshRate
        return 1.0 / TimeInterval(max(1, refreshRate))
    }

    private func refreshTerminalControl(in tab: TerminalTab) {
        setTerminalControl(isCommandRunning(in: tab) && tab.isAlternateScreenActive, in: tab)
    }

    private func setTerminalControl(_ isActive: Bool, in tab: TerminalTab) {
        guard tab.isTerminalControlActive != isActive else {
            updateCommandBarVisibility(for: tab)
            return
        }

        let wasAtBottom = tab.isScrolledToBottom
        tab.isTerminalControlActive = isActive
        if let runningBlock = latestRunningBlock(in: tab) {
            tab.blockViews[runningBlock.id]?.hidesLiveDuration = isActive
        }
        if isActive {
            stopRunningElapsedUpdates(for: tab)
        } else if isCommandRunning(in: tab) {
            startRunningElapsedUpdates(for: tab)
        }
        updatePassthroughVisibility(for: tab)
        updateCommandBarVisibility(for: tab)

        resizePtyToViewport(for: tab)
        focusInput(for: tab)
        if wasAtBottom { scrollToBottomNow(tab) }
    }

    private func updateCommandBarVisibility(for tab: TerminalTab) {
        onActivityChange?()
        let shouldShowCommandBar = tab.isFindMode || (!tab.isTerminalControlActive && !isCommandRunning(in: tab))
        guard tab.commandBarView.isHidden == shouldShowCommandBar else { return }
        tab.commandBarView.isHidden = !shouldShowCommandBar
        tab.commandSeparator.isHidden = !shouldShowCommandBar
        tab.updateCommandBarInset()
        tab.rootView.needsLayout = true
        tab.rootView.layoutSubtreeIfNeeded()
    }

    private func focusInput(for tab: TerminalTab) {
        guard activeTabID == tab.id else { return }
        view.window?.makeFirstResponder(commandFocusTarget(for: tab))
    }

    private func updatePassthroughVisibility(for tab: TerminalTab) {
        tab.ptyPassthroughView.isHidden = !shouldSendInputToPty(in: tab)
    }

    private func shouldSendInputToPty(in tab: TerminalTab) -> Bool {
        Self.shouldSendInputToPty(
            isFindMode: tab.isFindMode,
            isTerminalControlActive: tab.isTerminalControlActive,
            isCommandRunning: isCommandRunning(in: tab)
        )
    }

    private static func shouldSendInputToPty(
        isFindMode: Bool,
        isTerminalControlActive: Bool,
        isCommandRunning: Bool
    ) -> Bool {
        !isFindMode && (isTerminalControlActive || isCommandRunning)
    }

    private func resizePtyToViewport(for tab: TerminalTab) {
        guard let gridSize = terminalGridSize(for: tab) else { return }
        tab.outputProcessor.resize(rows: Int(gridSize.rows), cols: Int(gridSize.cols))
        tab.session.resize(rows: gridSize.rows, cols: gridSize.cols)
    }

    private func terminalGridSize(for tab: TerminalTab) -> TerminalGridSize? {
        var viewport = tab.scrollView.contentView.bounds
        viewport.size.height -= toolbarInset + tab.scrollView.contentInsets.bottom
        guard viewport.width > 0, viewport.height > 0 else { return nil }

        let contentSize = latestRunningBlock(in: tab)
            .flatMap { tab.blockViews[$0.id] }
            .map { $0.terminalContentSize(fitting: viewport.size) }
            ?? viewport.size

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let characterWidth = max(1, ceil(("W" as NSString).size(withAttributes: [.font: font]).width))
        let lineHeight = max(1, ceil(font.ascender - font.descender + font.leading))
        let cols = UInt16(max(20, Int(contentSize.width / characterWidth)))
        let rows = UInt16(max(5, Int(contentSize.height / lineHeight)))
        return TerminalGridSize(rows: rows, cols: cols)
    }

    private func handleTerminalMouseEvent(
        _ event: NSEvent,
        at point: NSPoint,
        in blockView: BlockView,
        blockID: UUID,
        tab: TerminalTab
    ) -> Bool {
        guard !event.modifierFlags.contains(.shift),
              activeTabID == tab.id,
              latestRunningBlock(in: tab)?.id == blockID,
              tab.session.supportsBinaryInput,
              let trackingMode = tab.mouseTrackingMode,
              let gridSize = terminalGridSize(for: tab),
              let cell = blockView.terminalCell(
                at: point,
                rows: Int(gridSize.rows),
                cols: Int(gridSize.cols)
              )
        else {
            return false
        }

        if let sequence = TerminalMouseEncoder.sequence(
            for: event,
            column: cell.column,
            row: cell.row,
            trackingMode: trackingMode,
            usesSGR: tab.usesSGRMouseMode
        ) {
            tab.outputProcessor.prioritizeNextOutputForInput()
            tab.session.write(sequence)
        }
        return true
    }

    private func tooltipOrigin(near point: NSPoint, size: NSSize) -> NSPoint {
        let bounds = view.bounds
        let offset: CGFloat = 14
        let margin: CGFloat = 10

        var x = point.x + offset
        if x + size.width + margin > bounds.maxX {
            x = point.x - size.width - offset
        }

        var y = point.y - size.height - offset
        if y < bounds.minY + margin {
            y = point.y + offset
        }

        x = min(max(bounds.minX + margin, x), bounds.maxX - size.width - margin)
        y = min(max(bounds.minY + margin, y), bounds.maxY - size.height - margin)
        return NSPoint(x: x, y: y)
    }

    private func addBlockView(_ block: TerminalBlock, to tab: TerminalTab) {
        let wasAtBottom = tab.isScrolledToBottom
        let separator = SeparatorView()
        tab.stackView.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: tab.stackView.widthAnchor).isActive = true

        let blockView = BlockView()
        blockView.usesPortalMaterials = standalone
        let previousBlock = tab.commandSeparator.blockAbove
        separator.blockAbove = previousBlock
        separator.blockBelow = blockView
        previousBlock?.bottomSeparator = separator
        blockView.topSeparator = separator
        blockView.bottomSeparator = tab.commandSeparator
        tab.commandSeparator.blockAbove = blockView
        blockView.update(with: block)
        blockView.onCopyMarkdown = { [weak self, weak tab] in
            guard let self else { return }
            let latest = tab?.blocks.first(where: { $0.id == block.id }) ?? block
            let exitCode: Int32?
            if case .completed(let code) = latest.state {
                exitCode = code
            } else {
                exitCode = nil
            }
            self.copy(markdownTranscript(command: latest.command, output: latest.output, exitCode: exitCode))
        }
        blockView.onTerminalMouseEvent = { [weak self, weak tab, weak blockView] event, point in
            guard let self, let tab, let blockView else { return false }
            return self.handleTerminalMouseEvent(event, at: point, in: blockView, blockID: block.id, tab: tab)
        }
        tab.stackView.addArrangedSubview(blockView)
        blockView.translatesAutoresizingMaskIntoConstraints = false
        blockView.widthAnchor.constraint(equalTo: tab.stackView.widthAnchor).isActive = true
        tab.blockViews[block.id] = blockView
        if tab.isFindMode {
            updateFindResults(in: tab, bounce: false)
        }
        if wasAtBottom { scrollToBottomNow(tab) }
    }

    private func ensureBlockView(for blockID: UUID, in tab: TerminalTab) {
        guard tab.blockViews[blockID] == nil,
              let block = tab.blocks.first(where: { $0.id == blockID })
        else {
            return
        }
        addBlockView(block, to: tab)
    }

    private func rebuildBlockViews(for tab: TerminalTab) {
        tab.commandSeparator.blockAbove = nil
        for view in tab.stackView.arrangedSubviews {
            tab.stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for block in tab.blocks {
            addBlockView(block, to: tab)
        }
    }

    private func runInitialCommandIfNeeded(in tab: TerminalTab) {
        guard tab.isShellReady else { return }
        if tab.blocks.isEmpty,
           let initialCommand = initialCommands.removeValue(forKey: tab.id) {
            tab.inputView.string = initialCommand.command
            submitCommand(
                in: tab,
                exitsShellAfterCompletion: initialCommand.exitsShellAfterCompletion
            )
            return
        }
        guard !didRunSelfTest, let selfTestCommand, tab.blocks.isEmpty else { return }
        didRunSelfTest = true
        tab.inputView.string = selfTestCommand
        submitCommand(in: tab)
    }

    private func confirmCloseIfNeeded(_ tab: TerminalTab) -> Bool {
        guard isCommandRunning(in: tab) else {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close this tab?"
        alert.informativeText = "A command is still running in this tab. Closing it will stop the shell session."
        alert.addButton(withTitle: "Close Tab")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func isCommandRunning(in tab: TerminalTab) -> Bool {
        tab.commandLifecycle.state.isCommandRunning
    }

    private func latestRunningBlock(in tab: TerminalTab) -> TerminalBlock? {
        tab.commandLifecycle.state.latestRunningBlock
    }

    private func scheduleBlockViewUpdate(for blockID: UUID, in tab: TerminalTab) {
        tab.pendingBlockViewUpdates.insert(blockID)
        guard !tab.isBlockViewUpdateScheduled else { return }

        tab.isBlockViewUpdateScheduled = true
        let delay = tab.isTerminalControlActive || tab.isAlternateScreenActive
            ? interactiveBlockViewRenderDelay
            : blockViewRenderDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.flushScheduledBlockViewUpdates(in: tab)
        }
    }

    private func flushScheduledBlockViewUpdates(in tab: TerminalTab) {
        let blockIDs = tab.pendingBlockViewUpdates
        tab.pendingBlockViewUpdates.removeAll(keepingCapacity: true)
        tab.isBlockViewUpdateScheduled = false

        for blockID in blockIDs {
            updateBlockViewNow(for: blockID, in: tab)
        }
    }

    private func updateBlockViewNow(for blockID: UUID, in tab: TerminalTab) {
        tab.pendingBlockViewUpdates.remove(blockID)
        guard let block = tab.blocks.first(where: { $0.id == blockID }) else { return }
        let wasAtBottom = tab.isScrolledToBottom
        ensureBlockView(for: blockID, in: tab)
        tab.blockViews[blockID]?.update(with: block)
        if wasAtBottom { scrollToBottomNow(tab) }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func markdownTranscript(command: String, output: String, exitCode: Int32?) -> String {
        var transcript = "```sh\n$ \(command)\n"
        if !output.isEmpty {
            transcript += output
            if !output.hasSuffix("\n") {
                transcript += "\n"
            }
        }
        if let exitCode {
            transcript += "# exit code: \(exitCode)\n"
        }
        transcript += "```"
        return transcript
    }

    private func scrollToBottom(_ tab: TerminalTab) {
        guard !tab.isScrollToBottomScheduled else { return }
        tab.isScrollToBottomScheduled = true
        DispatchQueue.main.async { [weak self] in
            tab.isScrollToBottomScheduled = false
            self?.scrollToBottomNow(tab)
        }
    }

    private func scrollToBottomNow(_ tab: TerminalTab) {
        tab.scrollToBottom()
    }

    private func decodeBase64(_ value: String) -> String? {
        guard let data = Data(base64Encoded: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var chunks: [[Element]] = []
        var index = startIndex
        while index < endIndex {
            let end = Swift.min(index + size, endIndex)
            chunks.append(Array(self[index..<end]))
            index = end
        }
        return chunks
    }
}

#endif

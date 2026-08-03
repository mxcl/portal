import AppKit
import Foundation
import QuartzCore
import SwiftUI

@_silgen_name("vaultty_ghostty_osc_command_type")
private func vaulttyGhosttyOscCommandType(_ payload: UnsafePointer<CChar>) -> Int32

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

private enum TahoeGlassPalette {
    static let windowCornerRadius: CGFloat = 22
    static let titleBarHeight: CGFloat = 50
    static let titleTabHeight: CGFloat = 34
    static let titleTabTopInset: CGFloat = titleBarHeight - titleTabHeight
    static let titleTabCornerRadius: CGFloat = max(0, windowCornerRadius - (titleTabTopInset * 0.535)) * 0.8
    static let titleTabBottomInset: CGFloat = 0
    static let titleContentTop: CGFloat = titleTabTopInset + titleTabHeight + titleTabBottomInset
    static let titleTabLeadingInset: CGFloat = 104
    static let titleTabMinimumWidth: CGFloat = 112
    static let titleTabMaximumWidth: CGFloat = 240
    static let titleTabTitleLeadingInset: CGFloat = 16
    static let titleTabTitleTrailingInset: CGFloat = 16
    static let titleTabTitleCloseTrailingInset: CGFloat = 34
    static let titleTabMeasurementSlack: CGFloat = 4
    static let titleTabCloseButtonSize: CGFloat = 16
    static let titleTabCloseButtonCornerRadius: CGFloat = 1.5
    static let titleTabCloseButtonTrailingInset: CGFloat = 8
    static let titleTabCloseButtonVerticalOffset: CGFloat = 1
    static let titleTabRunningIndicatorSize: CGFloat = 5
    static let titleHairlineEndpointGap: CGFloat = 1
    static let windowTintStart = NSColor.black.withAlphaComponent(0.30)
    static let windowTintMid = NSColor.black.withAlphaComponent(0.26)
    static let windowTintEnd = NSColor.black.withAlphaComponent(0.24)
    static let topBarTint = NSColor.black.withAlphaComponent(0.26)
    static let surfaceTint = NSColor.black.withAlphaComponent(0.18)
    static let failureSurfaceTint = NSColor.systemRed.withAlphaComponent(0.22)
    static let commandTint = NSColor.black.withAlphaComponent(0.22)
    static let hairline = NSColor.white.withAlphaComponent(0.12)
    static let titleTopHairline = NSColor.white.withAlphaComponent(0.20)
    static let titleText = NSColor.white.withAlphaComponent(0.44)
    static let titleTextActive = NSColor.white.withAlphaComponent(0.62)
    static let titleSegmentHoverFill = NSColor.white.withAlphaComponent(0.045)
}

private func mutedGitStatusColor(_ color: NSColor) -> NSColor {
    color.blended(withFraction: 0.1, of: .tertiaryLabelColor)
        ?? color.withAlphaComponent(0.75)
}

private func hostPrefixAttributedString(
    _ hostPrefix: String,
    color: NSColor
) -> NSAttributedString {
    NSAttributedString(
        string: hostPrefix.uppercased(),
        attributes: [
            .font: NSFont.systemFont(ofSize: 8, weight: .semibold),
            .foregroundColor: color.withAlphaComponent(0.34)
        ]
    )
}

private final class SeparatorView: NSBox {
    init() {
        super.init(frame: .zero)
        boxType = .separator
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

    static func headerButtonHitTestingSelfTest() -> Bool {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
        let picker = SessionPickerView(frame: NSRect(x: 20, y: 20, width: 40, height: 40))
        let stack = NSStackView(frame: picker.bounds)
        let header = NSView(frame: picker.bounds)
        let button = SessionHeaderAddButton(
            sessionRef: SessionRef(location: .relayMac("test"), sessionID: "first"),
            hostName: "test"
        )
        let replacement = SessionHeaderAddButton(
            sessionRef: SessionRef(location: .relayMac("test"), sessionID: "second"),
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
        return headerButton(at: localPoint) ?? candidateButton(at: localPoint)
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
        guard let text = NSPasteboard.general.string(forType: .string) else {
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

private final class TahoeGlassRootView: NSView {
    private let originalMaterialView = NonHitTestingVisualEffectView()
    private let contentColumnMaterialView = NSHostingView(rootView: ContentColumnBackground())
    private let tintView = NonHitTestingView()
    private let originalTintLayer = CAGradientLayer()
    private let topBarLayer = CAShapeLayer()
    private let topBarSeparatorLayer = CAShapeLayer()
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

    var onLayout: (() -> Void)?
    var onUpdateButtonMouseDown: (() -> Void)?
    var updateButtonFrame: CGRect?

    var activeTabFrame: CGRect? {
        didSet {
            guard activeTabFrame != oldValue else { return }
            needsLayout = true
        }
    }
    var tabStripFrame: CGRect? {
        didSet {
            guard tabStripFrame != oldValue else { return }
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = TahoeGlassPalette.windowCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        originalMaterialView.material = .underWindowBackground
        originalMaterialView.blendingMode = .behindWindow
        originalMaterialView.state = .active
        originalMaterialView.appearance = NSAppearance(named: .darkAqua)
        originalMaterialView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(originalMaterialView, positioned: .below, relativeTo: nil)

        contentColumnMaterialView.translatesAutoresizingMaskIntoConstraints = false

        tintView.wantsLayer = true
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

        topBarLayer.fillColor = TahoeGlassPalette.topBarTint.cgColor
        topBarLayer.fillRule = .evenOdd
        tintView.layer?.addSublayer(topBarLayer)

        topBarSeparatorLayer.fillColor = nil
        topBarSeparatorLayer.strokeColor = TahoeGlassPalette.hairline.cgColor
        topBarSeparatorLayer.lineWidth = 1
        tintView.layer?.addSublayer(topBarSeparatorLayer)

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

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if updateButtonFrame?.contains(point) == true {
            onUpdateButtonMouseDown?()
            return
        }

        let titlebarMinY = bounds.height - TahoeGlassPalette.titleContentTop
        if point.y >= titlebarMinY {
            window?.performDrag(with: event)
            return
        }

        super.mouseDown(with: event)
    }

    override func layout() {
        super.layout()
        onLayout?()
        originalTintLayer.frame = bounds
        let contentTop = TahoeGlassPalette.titleContentTop
        topBarLayer.frame = bounds
        topBarLayer.path = topBarPath(
            contentTop: contentTop,
            activeTabFrame: activeTabFrame,
            tabStripFrame: tabStripFrame
        )
        topBarSeparatorLayer.frame = bounds
        topBarSeparatorLayer.path = topBarSeparatorPath(
            y: max(0, bounds.height - contentTop),
            activeTabFrame: activeTabFrame
        )
    }

    private func updateBackgroundBlurEffect() {
        originalTintLayer.isHidden = backgroundBlurEffect != .original
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

    private func topBarPath(
        contentTop: CGFloat,
        activeTabFrame: CGRect?,
        tabStripFrame: CGRect?
    ) -> CGPath {
        let path = CGMutablePath()
        let topBarFrame = CGRect(
            x: 0,
            y: bounds.height - contentTop,
            width: bounds.width,
            height: contentTop
        )
        path.addRect(topBarFrame)
        if let activeTabFrame {
            let cutoutFrame = activeTabFrame.intersection(topBarFrame)
            if !cutoutFrame.isNull {
                let roundsLeadingCorner = tabStripFrame.map {
                    abs(cutoutFrame.minX - $0.minX) < 0.5
                } ?? false
                let roundsTrailingCorner = tabStripFrame.map {
                    abs(cutoutFrame.maxX - $0.maxX) < 0.5
                } ?? false
                path.addPath(topRoundedRectPath(
                    in: cutoutFrame,
                    radius: TahoeGlassPalette.titleTabCornerRadius,
                    roundsLeadingCorner: roundsLeadingCorner,
                    roundsTrailingCorner: roundsTrailingCorner
                ))
            }
        }

        return path
    }

    private func topRoundedRectPath(
        in rect: CGRect,
        radius requestedRadius: CGFloat,
        roundsLeadingCorner: Bool,
        roundsTrailingCorner: Bool
    ) -> CGPath {
        guard roundsLeadingCorner || roundsTrailingCorner else {
            let path = CGMutablePath()
            path.addRect(rect)
            return path
        }

        let radius = min(requestedRadius, rect.width / 2, rect.height)
        let controlOffset = radius * 0.5522847498307936
        let path = CGMutablePath()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        if roundsLeadingCorner {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
            path.addCurve(
                to: CGPoint(x: rect.minX + radius, y: rect.maxY),
                control1: CGPoint(x: rect.minX, y: rect.maxY - radius + controlOffset),
                control2: CGPoint(x: rect.minX + radius - controlOffset, y: rect.maxY)
            )
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }

        if roundsTrailingCorner {
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
            path.addCurve(
                to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
                control1: CGPoint(x: rect.maxX - radius + controlOffset, y: rect.maxY),
                control2: CGPoint(x: rect.maxX, y: rect.maxY - radius + controlOffset)
            )
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }

    private func topBarSeparatorPath(y: CGFloat, activeTabFrame: CGRect?) -> CGPath {
        let path = CGMutablePath()
        guard let activeTabFrame,
              y >= activeTabFrame.minY,
              y <= activeTabFrame.maxY
        else {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: bounds.width, y: y))
            return path
        }

        let endpointGap = TahoeGlassPalette.titleHairlineEndpointGap
        let gapStart = max(0, floor(activeTabFrame.minX) - endpointGap)
        let gapEnd = min(bounds.width, ceil(activeTabFrame.maxX) + endpointGap)
        if gapStart > 0 {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: gapStart, y: y))
        }
        if gapEnd < bounds.width {
            path.move(to: CGPoint(x: gapEnd, y: y))
            path.addLine(to: CGPoint(x: bounds.width, y: y))
        }
        return path
    }
}

private final class TitleTabBorderView: NSView {
    weak var tabStack: NSStackView?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        TahoeGlassPalette.titleTopHairline.setStroke()
        let outline = topRoundedOutlinePath(
            in: bounds.insetBy(dx: 0.5, dy: 0.5),
            radius: TahoeGlassPalette.titleTabCornerRadius
        )
        outline.lineWidth = 1
        outline.stroke()

        TahoeGlassPalette.titleTopHairline.setFill()

        guard let tabStack else { return }
        let visibleSubviews = tabStack.arrangedSubviews.filter { !$0.isHidden }
        let separatorEndpointInset = min(
            TahoeGlassPalette.titleHairlineEndpointGap,
            bounds.height / 2
        )
        for subview in visibleSubviews.dropLast() {
            let rect = subview.convert(subview.bounds, to: self)
            NSRect(
                x: floor(rect.maxX) - 1,
                y: separatorEndpointInset,
                width: 1,
                height: max(0, bounds.height - separatorEndpointInset)
            ).fill()
        }
    }

    private func topRoundedOutlinePath(in rect: NSRect, radius requestedRadius: CGFloat) -> NSBezierPath {
        let radius = min(requestedRadius, rect.width / 2, rect.height)
        let controlOffset = radius * 0.5522847498307936
        let path = NSBezierPath()

        path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
        path.curve(
            to: NSPoint(x: rect.minX + radius, y: rect.minY),
            controlPoint1: NSPoint(x: rect.minX, y: rect.minY + radius - controlOffset),
            controlPoint2: NSPoint(x: rect.minX + radius - controlOffset, y: rect.minY)
        )
        path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
        path.curve(
            to: NSPoint(x: rect.maxX, y: rect.minY + radius),
            controlPoint1: NSPoint(x: rect.maxX - radius + controlOffset, y: rect.minY),
            controlPoint2: NSPoint(x: rect.maxX, y: rect.minY + radius - controlOffset)
        )
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))

        return path
    }
}

private final class TitleTabStackView: NSStackView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class TitleTabCloseButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { needsDisplay = true }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var isHidden: Bool {
        didSet {
            if isHidden {
                isHovering = false
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
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
        if isHovering {
            let side = min(bounds.width, bounds.height)
            let hoverRect = NSRect(
                x: bounds.midX - (side / 2),
                y: bounds.midY - (side / 2),
                width: side,
                height: side
            )
            NSColor.white.withAlphaComponent(0.08).setFill()
            NSBezierPath(
                roundedRect: hoverRect,
                xRadius: TahoeGlassPalette.titleTabCloseButtonCornerRadius,
                yRadius: TahoeGlassPalette.titleTabCloseButtonCornerRadius
            ).fill()
        }
        super.draw(dirtyRect)
    }
}

private func titleSegmentFillPath(
    in rect: NSRect,
    isFlipped: Bool,
    roundsLeadingTopCorner: Bool,
    roundsTrailingTopCorner: Bool
) -> NSBezierPath {
    let radius = min(TahoeGlassPalette.titleTabCornerRadius, rect.width / 2, rect.height)
    let controlOffset = radius * 0.5522847498307936
    let path = NSBezierPath()

    guard roundsLeadingTopCorner || roundsTrailingTopCorner else {
        path.appendRect(rect)
        return path
    }

    if isFlipped {
        path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        if roundsLeadingTopCorner {
            path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
            path.curve(
                to: NSPoint(x: rect.minX + radius, y: rect.minY),
                controlPoint1: NSPoint(x: rect.minX, y: rect.minY + radius - controlOffset),
                controlPoint2: NSPoint(x: rect.minX + radius - controlOffset, y: rect.minY)
            )
        } else {
            path.line(to: NSPoint(x: rect.minX, y: rect.minY))
        }

        if roundsTrailingTopCorner {
            path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
            path.curve(
                to: NSPoint(x: rect.maxX, y: rect.minY + radius),
                controlPoint1: NSPoint(x: rect.maxX - radius + controlOffset, y: rect.minY),
                controlPoint2: NSPoint(x: rect.maxX, y: rect.minY + radius - controlOffset)
            )
        } else {
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        }

        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
    } else {
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        if roundsLeadingTopCorner {
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY - radius))
            path.curve(
                to: NSPoint(x: rect.minX + radius, y: rect.maxY),
                controlPoint1: NSPoint(x: rect.minX, y: rect.maxY - radius + controlOffset),
                controlPoint2: NSPoint(x: rect.minX + radius - controlOffset, y: rect.maxY)
            )
        } else {
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        }

        if roundsTrailingTopCorner {
            path.line(to: NSPoint(x: rect.maxX - radius, y: rect.maxY))
            path.curve(
                to: NSPoint(x: rect.maxX, y: rect.maxY - radius),
                controlPoint1: NSPoint(x: rect.maxX - radius + controlOffset, y: rect.maxY),
                controlPoint2: NSPoint(x: rect.maxX, y: rect.maxY - radius + controlOffset)
            )
        } else {
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        }

        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
    }

    path.close()
    return path
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
    private static let linkCapsuleColor = NSColor.white.withAlphaComponent(0.10)
    private var linkTrackingArea: NSTrackingArea?
    private var firstMouseLink: (value: Any, characterIndex: Int)?
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
        let firstMouseLink = firstMouseLink
        super.mouseDown(with: event)
        guard self.firstMouseLink != nil, let firstMouseLink else { return }
        self.firstMouseLink = nil
        clicked(onLink: firstMouseLink.value, at: firstMouseLink.characterIndex)
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

private final class HoverMenuButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { updateHoverAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = "..."
        isBordered = false
        bezelStyle = .regularSquare
        controlSize = .regular
        font = .systemFont(ofSize: 15, weight: .semibold)
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
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
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

    private func updateHoverAppearance() {
        layer?.backgroundColor = (isHovering
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.clear
        ).cgColor
        contentTintColor = isHovering ? .labelColor : .secondaryLabelColor
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
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
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

    private func updateHoverAppearance() {
        layer?.backgroundColor = (isHovering
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.clear
        ).cgColor
        contentTintColor = isHovering ? .labelColor : .secondaryLabelColor
    }
}

private final class FindCloseButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { updateAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        image = NSImage(
            systemSymbolName: "multiply",
            accessibilityDescription: "Close Find"
        )
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        toolTip = "Close Find"
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.clear.cgColor
        contentTintColor = .secondaryLabelColor
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
            owner: self,
            userInfo: nil
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

    private func updateAppearance() {
        layer?.backgroundColor = (isHovering
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.clear
        ).cgColor
        contentTintColor = isHovering ? .labelColor : .secondaryLabelColor
    }
}

private final class BlockView: NSView {
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

    private let commandLabel = SelectableBlockTextField()
    private let metaLabel = SelectableBlockTextField()
    private let outputView = BlockOutputTextView(frame: .zero)
    private let copyMarkdownButton = HoverCopyMarkdownButton(frame: .zero)
    private let menuButton = HoverMenuButton(frame: .zero)
    private let findReticuleLayer = CALayer()
    private var outputHeightConstraint: NSLayoutConstraint?
    private var minimumHeightConstraint: NSLayoutConstraint?
    private var contentBottomConstraint: NSLayoutConstraint?
    private var hasVisibleOutput = false
    private var lastMeasuredOutputWidth: CGFloat = 0
    private var needsOutputHeightMeasurement = true
    private var renderedOutputRevision = -1
    private var lastBlock: TerminalBlock?
    private var findSelectionTarget: FindResultTarget?
    private var findSelectionRange: NSRange?

    var onCopyCommand: (() -> Void)?
    var onCopyOutput: (() -> Void)?
    var onCopyMarkdown: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.borderWidth = 0
        layer?.backgroundColor = TahoeGlassPalette.surfaceTint.cgColor
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

        menuButton.target = self
        menuButton.action = #selector(showMenu)
        menuButton.setButtonType(.momentaryPushIn)
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        copyMarkdownButton.target = self
        copyMarkdownButton.action = #selector(copyMarkdown)
        copyMarkdownButton.setButtonType(.momentaryPushIn)
        copyMarkdownButton.translatesAutoresizingMaskIntoConstraints = false

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(metaLabel)
        header.addSubview(copyMarkdownButton)
        header.addSubview(menuButton)
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        commandLabel.translatesAutoresizingMaskIntoConstraints = false
        commandLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let content = NSStackView(views: [header, commandLabel, outputView])
        content.orientation = .vertical
        content.spacing = 0
        content.setCustomSpacing(6, after: commandLabel)
        content.alignment = .leading
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

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
            content.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            metaLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            metaLabel.topAnchor.constraint(equalTo: header.topAnchor),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: copyMarkdownButton.leadingAnchor, constant: -8),
            copyMarkdownButton.centerYAnchor.constraint(equalTo: menuButton.centerYAnchor),
            copyMarkdownButton.trailingAnchor.constraint(equalTo: menuButton.leadingAnchor, constant: -4),
            copyMarkdownButton.widthAnchor.constraint(equalTo: menuButton.widthAnchor),
            copyMarkdownButton.heightAnchor.constraint(equalTo: menuButton.heightAnchor),
            menuButton.topAnchor.constraint(equalTo: header.topAnchor),
            menuButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            menuButton.bottomAnchor.constraint(lessThanOrEqualTo: header.bottomAnchor),
            commandLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            outputView.widthAnchor.constraint(equalTo: content.widthAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 36),
            menuButton.heightAnchor.constraint(equalToConstant: 28),
            outputHeightConstraint,
            minimumHeightConstraint
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(with block: TerminalBlock, now: Date = Date()) {
        lastBlock = block
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
            layer?.backgroundColor = TahoeGlassPalette.commandTint.cgColor
            metadata.append(MetadataSegment(
                text: liveDurationText(startedAt: block.startedAt, now: now),
                color: .tertiaryLabelColor
            ))
            minimumHeightConstraint?.constant = Metrics.runningMinimumHeight
            contentBottomConstraint?.isActive = hasVisibleOutput
        case .completed(let code):
            minimumHeightConstraint?.constant = 0
            contentBottomConstraint?.isActive = true
            layer?.backgroundColor = (code == 0
                ? TahoeGlassPalette.surfaceTint
                : TahoeGlassPalette.failureSurfaceTint
            ).cgColor
            if let duration = durationText(for: block) {
                metadata.append(MetadataSegment(text: duration, color: .tertiaryLabelColor))
            }
            if let timestamp = completionTimestampText(for: block) {
                metadata.append(MetadataSegment(text: timestamp, color: .tertiaryLabelColor))
            }
            if code != 0 {
                metadata.append(MetadataSegment(text: "exit \(code)", color: .secondaryLabelColor))
            }
        }
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
            guard let rect = outputRect(for: range) else {
                scrollToVisible(convert(outputView.bounds.insetBy(dx: 0, dy: -8), from: outputView))
                return
            }
            scrollToVisible(convert(rect.insetBy(dx: 0, dy: -8), from: outputView))
        }
    }

    override func layout() {
        super.layout()
        if abs(outputView.bounds.width - lastMeasuredOutputWidth) > 0.5 {
            needsOutputHeightMeasurement = true
            updateOutputHeight()
        }
    }

    @objc private func showMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Copy Command", action: #selector(copyCommand), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Copy Output", action: #selector(copyOutput), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Copy Markdown", action: #selector(copyMarkdown), keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: menuButton.bounds.minX, y: menuButton.bounds.minY),
            in: menuButton
        )
    }

    @objc private func copyCommand() { onCopyCommand?() }

    @objc private func copyOutput() { onCopyOutput?() }

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

private final class TitleTabButton: NSButton {
    let tabID: UUID
    private let closeButton = TitleTabCloseButton()
    private let runningIndicatorView = TitleTabRunningIndicatorView()
    private let titleContentView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var titleText = ""
    private var hostPrefix: String?
    private var currentTitleColor = TahoeGlassPalette.titleText
    private var toolTipText: String?
    private var preferredWidthConstraint: NSLayoutConstraint?
    private var minimumWidthConstraint: NSLayoutConstraint?
    private var titleContentWidthConstraint: NSLayoutConstraint?
    private var titleContentTrailingConstraint: NSLayoutConstraint?
    private var fillColor = NSColor.clear {
        didSet { needsDisplay = true }
    }
    var isSelectedTab = false {
        didSet { updateAppearance() }
    }
    var showsRunningIndicator = false {
        didSet { updateAppearance() }
    }
    var roundsLeadingTopCorner = false {
        didSet {
            guard roundsLeadingTopCorner != oldValue else { return }
            needsDisplay = true
        }
    }
    var roundsTrailingTopCorner = false {
        didSet {
            guard roundsTrailingTopCorner != oldValue else { return }
            needsDisplay = true
        }
    }
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { updateAppearance() }
    }

    init(tabID: UUID, title: String) {
        self.tabID = tabID
        super.init(frame: .zero)
        self.title = ""
        isBordered = false
        bezelStyle = .regularSquare
        controlSize = .regular
        font = .systemFont(ofSize: 13, weight: .semibold)
        alignment = .center
        lineBreakMode = .byTruncatingTail
        imagePosition = .noImage
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.backgroundColor = NSColor.clear.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        contentTintColor = TahoeGlassPalette.titleText
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        titleContentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleContentView)

        titleLabel.stringValue = title
        titleLabel.font = font
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true
        titleLabel.textColor = TahoeGlassPalette.titleText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.cell?.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleContentView.addSubview(titleLabel)

        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close Tab"
        )
        closeButton.imagePosition = .imageOnly
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        closeButton.contentTintColor = TahoeGlassPalette.titleText
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        runningIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(runningIndicatorView)

        let titleContentWidthConstraint = titleContentView.widthAnchor.constraint(
            equalToConstant: titleContentWidth
        )
        titleContentWidthConstraint.priority = .defaultHigh
        self.titleContentWidthConstraint = titleContentWidthConstraint

        let titleContentTrailingConstraint = titleContentView.trailingAnchor.constraint(
            lessThanOrEqualTo: trailingAnchor,
            constant: -TahoeGlassPalette.titleTabTitleCloseTrailingInset
        )
        self.titleContentTrailingConstraint = titleContentTrailingConstraint

        let titleContentCenterXConstraint = titleContentView.centerXAnchor.constraint(equalTo: centerXAnchor)
        titleContentCenterXConstraint.priority = .defaultLow

        NSLayoutConstraint.activate([
            titleContentCenterXConstraint,
            titleContentView.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleContentView.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: TahoeGlassPalette.titleTabTitleLeadingInset
            ),
            titleContentTrailingConstraint,
            titleContentWidthConstraint,
            titleContentView.heightAnchor.constraint(equalTo: heightAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: titleContentView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(
                equalTo: titleContentView.trailingAnchor
            ),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -TahoeGlassPalette.titleTabCloseButtonTrailingInset
            ),
            closeButton.centerYAnchor.constraint(
                equalTo: centerYAnchor,
                constant: TahoeGlassPalette.titleTabCloseButtonVerticalOffset
            ),
            closeButton.widthAnchor.constraint(equalToConstant: TahoeGlassPalette.titleTabCloseButtonSize),
            closeButton.heightAnchor.constraint(equalToConstant: TahoeGlassPalette.titleTabCloseButtonSize),

            runningIndicatorView.centerXAnchor.constraint(equalTo: closeButton.centerXAnchor),
            runningIndicatorView.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            runningIndicatorView.widthAnchor.constraint(equalToConstant: TahoeGlassPalette.titleTabRunningIndicatorSize),
            runningIndicatorView.heightAnchor.constraint(equalToConstant: TahoeGlassPalette.titleTabRunningIndicatorSize)
        ])

        updateTitle(title)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if !closeButton.isHidden {
            let closePoint = closeButton.convert(point, from: self)
            if let closeHit = closeButton.hitTest(closePoint) {
                return closeHit
            }
        }
        return self
    }

    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        let fillRect = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 1))
        titleSegmentFillPath(
            in: fillRect,
            isFlipped: isFlipped,
            roundsLeadingTopCorner: roundsLeadingTopCorner,
            roundsTrailingTopCorner: roundsTrailingTopCorner
        ).fill()
        super.draw(dirtyRect)
    }

    override func layout() {
        super.layout()
        updateToolTipForCurrentLayout()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth, height: TahoeGlassPalette.titleTabHeight)
    }

    var widthConstraints: [NSLayoutConstraint] {
        let preferredWidthConstraint = widthAnchor.constraint(equalToConstant: preferredWidth)
        preferredWidthConstraint.priority = .defaultHigh
        self.preferredWidthConstraint = preferredWidthConstraint
        let minimumWidthConstraint = widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth)
        self.minimumWidthConstraint = minimumWidthConstraint

        return [
            preferredWidthConstraint,
            minimumWidthConstraint
        ]
    }

    private var minimumWidth: CGFloat {
        TahoeGlassPalette.titleTabMinimumWidth
    }

    private var preferredWidth: CGFloat {
        let horizontalInsets = TahoeGlassPalette.titleTabTitleLeadingInset
            + TahoeGlassPalette.titleTabTitleCloseTrailingInset
            + TahoeGlassPalette.titleTabMeasurementSlack
        let width = titleTextWidth + horizontalInsets
        return min(
            TahoeGlassPalette.titleTabMaximumWidth,
            max(TahoeGlassPalette.titleTabMinimumWidth, width)
        )
    }

    private var titleTextWidth: CGFloat {
        let attributedTitle = titleLabel.attributedStringValue
        if attributedTitle.length > 0 {
            return ceil(attributedTitle.size().width)
        }
        return ceil((titleLabel.stringValue as NSString).size(withAttributes: [
            .font: titleLabel.font ?? NSFont.systemFont(ofSize: 13, weight: .semibold)
        ]).width)
    }

    private var titleContentWidth: CGFloat {
        min(
            titleTextWidth,
            TahoeGlassPalette.titleTabMaximumWidth
                - TahoeGlassPalette.titleTabTitleLeadingInset
                - TahoeGlassPalette.titleTabTitleCloseTrailingInset
                - TahoeGlassPalette.titleTabMeasurementSlack
        )
    }

    func configureClose(target: AnyObject?, action: Selector) {
        closeButton.target = target
        closeButton.action = action
    }

    func containsCloseButton(at point: NSPoint) -> Bool {
        !closeButton.isHidden && closeButton.frame.contains(point)
    }

    func updateTitle(_ title: String, hostPrefix: String? = nil, detail: String? = nil) {
        titleText = title
        self.hostPrefix = hostPrefix?.trimmingCharacters(in: .whitespacesAndNewlines)
        applyTitleText()
        let fullTitle = self.hostPrefix.map { "\($0):\(title)" } ?? title
        toolTipText = detail ?? fullTitle
        setAccessibilityLabel(fullTitle)
        titleContentWidthConstraint?.constant = titleContentWidth
        preferredWidthConstraint?.constant = preferredWidth
        minimumWidthConstraint?.constant = minimumWidth
        invalidateIntrinsicContentSize()
        updateToolTipForCurrentLayout()
    }

    private func applyTitleText() {
        let baseFont = titleLabel.font ?? NSFont.systemFont(ofSize: 13, weight: .semibold)
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: currentTitleColor
        ]
        guard let hostPrefix,
              !hostPrefix.isEmpty
        else {
            titleLabel.attributedStringValue = NSAttributedString(
                string: titleText,
                attributes: titleAttributes
            )
            return
        }

        let attributedTitle = NSMutableAttributedString(
            attributedString: hostPrefixAttributedString(hostPrefix, color: currentTitleColor)
        )
        attributedTitle.append(NSAttributedString(string: "  "))
        attributedTitle.append(NSAttributedString(
            string: titleText,
            attributes: titleAttributes
        ))
        titleLabel.attributedStringValue = attributedTitle
    }

    private func updateToolTipForCurrentLayout() {
        guard titleLabel.bounds.width > 0,
              titleTextWidth > titleLabel.bounds.width + 0.5,
              let toolTipText,
              !toolTipText.isEmpty
        else {
            toolTip = nil
            return
        }

        toolTip = toolTipText
    }

    private func updateAppearance() {
        let titleColor: NSColor
        if isSelectedTab {
            fillColor = .clear
            titleColor = TahoeGlassPalette.titleTextActive
        } else if isHovering {
            fillColor = TahoeGlassPalette.titleSegmentHoverFill
            titleColor = TahoeGlassPalette.titleTextActive
        } else {
            fillColor = .clear
            titleColor = TahoeGlassPalette.titleText
        }
        currentTitleColor = titleColor
        contentTintColor = titleColor
        applyTitleText()
        closeButton.isHidden = !isHovering
        closeButton.contentTintColor = titleColor
        runningIndicatorView.isHidden = isHovering || !showsRunningIndicator
        runningIndicatorView.fillColor = titleColor
    }
}

private final class TitleTabRunningIndicatorView: NSView {
    var fillColor = TahoeGlassPalette.titleText {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

private final class TitleAddButton: NSButton {
    private var fillColor = NSColor.clear {
        didSet { needsDisplay = true }
    }
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { updateAppearance() }
    }
    var roundsLeadingTopCorner = false {
        didSet {
            guard roundsLeadingTopCorner != oldValue else { return }
            needsDisplay = true
        }
    }
    var roundsTrailingTopCorner = false {
        didSet {
            guard roundsTrailingTopCorner != oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = "+"
        isBordered = false
        bezelStyle = .regularSquare
        controlSize = .regular
        font = .systemFont(ofSize: 18, weight: .medium)
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.backgroundColor = NSColor.clear.cgColor
        contentTintColor = TahoeGlassPalette.titleText
        translatesAutoresizingMaskIntoConstraints = false
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
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
        fillColor.setFill()
        let fillRect = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 1))
        titleSegmentFillPath(
            in: fillRect,
            isFlipped: isFlipped,
            roundsLeadingTopCorner: roundsLeadingTopCorner,
            roundsTrailingTopCorner: roundsTrailingTopCorner
        ).fill()
        super.draw(dirtyRect)
    }

    private func updateAppearance() {
        fillColor = isHovering ? TahoeGlassPalette.titleSegmentHoverFill : .clear
        contentTintColor = isHovering ? TahoeGlassPalette.titleTextActive : TahoeGlassPalette.titleText
    }
}

private final class TitleUpdateButton: NSButton {
    static let visibleWidth: CGFloat = 94
    static let installingWidth: CGFloat = 110
    static let visibleHeight: CGFloat = 28

    private enum Metrics {
        static let cornerRadius: CGFloat = 9
        static let horizontalInset: CGFloat = 11
        static let iconTextSpacing: CGFloat = 7
        static let iconSize: CGFloat = 14
        static let symbolPointSize: CGFloat = 12
    }

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { updateAppearance() }
    }
    private var isPressing = false {
        didSet { updateAppearance() }
    }
    var isInstalling = false {
        didSet {
            guard isInstalling != oldValue else { return }
            updateContent()
            updateAppearance()
        }
    }

    override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        image = nil
        isBordered = false
        bezelStyle = .regularSquare
        controlSize = .regular
        font = .systemFont(ofSize: 13, weight: .semibold)
        focusRingType = .none
        alignment = .center
        wantsLayer = true
        layer?.cornerRadius = Metrics.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel("Install staged update")
        setButtonType(.momentaryChange)

        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Metrics.symbolPointSize,
            weight: .semibold
        )
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        titleLabel.font = font
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalInset),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Metrics.iconSize),

            titleLabel.leadingAnchor.constraint(
                equalTo: iconView.trailingAnchor,
                constant: Metrics.iconTextSpacing
            ),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -Metrics.horizontalInset
            ),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        updateContent()
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        triggerAction()
    }

    func triggerAction() {
        guard isEnabled else { return }
        isPressing = true
        if let action {
            NSApp.sendAction(action, to: target, from: self)
        }
        DispatchQueue.main.async { [weak self] in
            self?.isPressing = false
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            cornerWidth: Metrics.cornerRadius,
            cornerHeight: Metrics.cornerRadius,
            transform: nil
        )
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: isInstalling ? Self.installingWidth : Self.visibleWidth,
            height: Self.visibleHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        drawBackground()
        drawBorder()
    }

    private var accentColor: NSColor {
        NSColor(calibratedRed: 0.52, green: 0.92, blue: 0.78, alpha: 1)
    }

    private var labelColor: NSColor {
        if !isEnabled && !isInstalling {
            return TahoeGlassPalette.titleText
        }
        if isPressing {
            return NSColor.white.withAlphaComponent(0.88)
        }
        return NSColor(calibratedRed: 0.86, green: 1.0, blue: 0.94, alpha: 0.92)
    }

    private var gradientColors: [NSColor] {
        if !isEnabled && !isInstalling {
            return [
                NSColor.white.withAlphaComponent(0.08),
                NSColor.white.withAlphaComponent(0.04)
            ]
        }
        if isPressing {
            return [
                accentColor.withAlphaComponent(0.18),
                NSColor.white.withAlphaComponent(0.08)
            ]
        }
        if isHovering {
            return [
                accentColor.withAlphaComponent(0.26),
                NSColor.white.withAlphaComponent(0.12)
            ]
        }
        if isInstalling {
            return [
                accentColor.withAlphaComponent(0.20),
                NSColor.white.withAlphaComponent(0.10)
            ]
        }
        return [
            NSColor.white.withAlphaComponent(0.17),
            NSColor.white.withAlphaComponent(0.09)
        ]
    }

    private var borderColor: NSColor {
        if !isEnabled && !isInstalling {
            return NSColor.white.withAlphaComponent(0.09)
        }
        if isHovering || isPressing || isInstalling {
            return accentColor.withAlphaComponent(0.38)
        }
        return NSColor.white.withAlphaComponent(0.17)
    }

    private func updateContent() {
        titleLabel.stringValue = isInstalling ? "Installing" : "Update"
        let icon = NSImage(
            systemSymbolName: isInstalling ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath",
            accessibilityDescription: isInstalling ? "Installing Update" : "Install Update"
        )
        icon?.isTemplate = true
        iconView.image = icon
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Metrics.symbolPointSize,
            weight: .semibold
        )
        invalidateIntrinsicContentSize()
    }

    private func updateAppearance() {
        titleLabel.textColor = labelColor
        iconView.contentTintColor = labelColor
        contentTintColor = labelColor
        layer?.shadowColor = accentColor.cgColor
        layer?.shadowOpacity = Float((isHovering || isInstalling) && isEnabled ? 0.22 : 0.10)
        layer?.shadowRadius = (isHovering || isInstalling) && isEnabled ? 7 : 3
        layer?.shadowOffset = .zero
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func drawBackground() {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: Metrics.cornerRadius,
            yRadius: Metrics.cornerRadius
        )
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(colors: gradientColors)?.draw(in: path, angle: 90)

        let glossRect = NSRect(
            x: rect.minX + Metrics.horizontalInset,
            y: isFlipped ? rect.minY + 1 : rect.maxY - 2,
            width: max(0, rect.width - (Metrics.horizontalInset * 2)),
            height: 1
        )
        NSColor.white.withAlphaComponent(isHovering ? 0.22 : 0.14).setFill()
        glossRect.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawBorder() {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Metrics.cornerRadius,
            yRadius: Metrics.cornerRadius
        )
        path.lineWidth = 1
        borderColor.setStroke()
        path.stroke()
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

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("VaulttyPassthroughRoutingSelfTest"))
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

private final class TerminalOutputProcessor {
    struct Snapshot {
        let blockID: UUID
        let plainText: String
        let attributedText: NSAttributedString
        let isAlternateScreenActive: Bool
        let isApplicationCursorModeActive: Bool
    }

    enum Event {
        case snapshot(Snapshot)
        case marker(VaulttyMarker, isReplay: Bool)
        case replayCommandStarted(blockID: UUID, command: String)
    }

    var onEvent: ((Event) -> Void)?
    var onTerminalResponse: ((String) -> Void)?

    private let queue = DispatchQueue(label: "com.automicvault.vaultty.output-render", qos: .userInitiated)
    private let flushDelay: DispatchTimeInterval
    private let terminalScreen = Ansi.TerminalScreen(rows: 30, cols: 100)
    private let styledRenderer = Ansi.StyledTextRenderer(rows: 30)
    private var pendingShellOutput = ""
    private var isShellOutputFlushScheduled = false
    private var isInputFeedbackPending = false
    private var markerParser = VaulttyMarkerParser()
    private var pendingBlockID: UUID?
    private var activeBlockID: UUID?
    private var activeBlockCwd: String?
    private var isReplayingCommand = false
    private var isReplayingHistoryOutput = false
    private var usesPagerScreenRendering = false
    private var didSeeAlternateScreenSwitch = false
    private var isAlternateScreenActive = false
    private var isApplicationCursorModeActive = false
    private var rows = 30
    private var cols = 100

    init(flushDelay: DispatchTimeInterval = .milliseconds(33)) {
        self.flushDelay = flushDelay
    }

    func resetForCommand(blockID: UUID, cwd: String, usesPagerScreenRendering: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingShellOutput.removeAll(keepingCapacity: true)
            self.isShellOutputFlushScheduled = false
            self.isInputFeedbackPending = false
            self.markerParser.reset()
            self.pendingBlockID = blockID
            self.activeBlockID = nil
            self.activeBlockCwd = cwd
            self.isReplayingCommand = false
            self.usesPagerScreenRendering = usesPagerScreenRendering
            self.didSeeAlternateScreenSwitch = false
            self.isAlternateScreenActive = false
            self.isApplicationCursorModeActive = false
            self.terminalScreen.resetForCommand()
            self.styledRenderer.reset()
        }
    }

    func resetForReplay() {
        queue.async { [weak self] in
            guard let self else { return }
            self.resetForReplayOnQueue()
        }
    }

    func replayShellOutput(_ text: String, completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.isReplayingHistoryOutput = true
            self.resetForReplayOnQueue()
            self.replayShellOutputChunk(text, startingAt: text.startIndex, completion: completion)
        }
    }

    func enqueueShellOutput(_ text: String) {
        queue.async { [weak self] in
            self?.enqueueShellOutputOnQueue(text)
        }
    }

    func prioritizeNextOutputForInput() {
        queue.async { [weak self] in
            self?.isInputFeedbackPending = true
        }
    }

    func flushAndFinish(_ completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.flushPendingShellOutputOnQueue()
            self.activeBlockID = nil
            self.activeBlockCwd = nil
            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    func resize(rows: Int, cols: Int) {
        queue.async { [weak self] in
            self?.rows = rows
            self?.cols = cols
            self?.terminalScreen.resize(rows: rows, cols: cols)
            self?.styledRenderer.resize(rows: rows)
        }
    }

    private func enqueueShellOutputOnQueue(_ text: String) {
        if isReplayingHistoryOutput {
            pendingShellOutput += text
            return
        }

        pendingShellOutput += text
        if consumeInputFeedbackPriority() {
            flushPendingShellOutputOnQueue()
            return
        }
        guard !isShellOutputFlushScheduled else { return }

        isShellOutputFlushScheduled = true
        queue.asyncAfter(deadline: .now() + flushDelay) { [weak self] in
            self?.flushPendingShellOutputOnQueue()
        }
    }

    private func consumeInputFeedbackPriority() -> Bool {
        guard isInputFeedbackPending else { return false }
        isInputFeedbackPending = false
        return true
    }

    private func replayShellOutputChunk(_ text: String, startingAt index: String.Index, completion: (() -> Void)?) {
        guard index < text.endIndex else {
            isReplayingHistoryOutput = false
            flushPendingShellOutputOnQueue()
            DispatchQueue.main.async {
                completion?()
            }
            return
        }

        let chunkSize = 64 * 1024
        let end = text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
        consumeShellOutput(String(text[index..<end]))
        queue.asyncAfter(deadline: .now() + .milliseconds(8)) { [weak self] in
            self?.replayShellOutputChunk(text, startingAt: end, completion: completion)
        }
    }

    private func resetForReplayOnQueue() {
        pendingShellOutput.removeAll(keepingCapacity: true)
        isShellOutputFlushScheduled = false
        isInputFeedbackPending = false
        markerParser.reset()
        pendingBlockID = nil
        activeBlockID = nil
        activeBlockCwd = nil
        isReplayingCommand = false
        usesPagerScreenRendering = false
        didSeeAlternateScreenSwitch = false
        isAlternateScreenActive = false
        isApplicationCursorModeActive = false
        terminalScreen.resetForCommand()
        styledRenderer.reset()
    }

    private func flushPendingShellOutputOnQueue() {
        guard !pendingShellOutput.isEmpty else {
            isShellOutputFlushScheduled = false
            return
        }

        let text = pendingShellOutput
        pendingShellOutput.removeAll(keepingCapacity: true)
        isShellOutputFlushScheduled = false
        consumeShellOutput(text)
    }

    private func consumeShellOutput(_ text: String) {
        for response in terminalResponses(in: text) {
            onTerminalResponse?(response)
        }

        for event in markerParser.consume(text) {
            switch event {
            case .text(let visible):
                flushVisible(visible)
            case .marker(let marker):
                emit(.marker(marker, isReplay: isReplayingCommand))
                if case .commandStarted(let command) = marker.kind {
                    if let pendingBlockID {
                        activeBlockID = pendingBlockID
                        self.pendingBlockID = nil
                        isReplayingCommand = false
                    } else {
                        let blockID = UUID()
                        terminalScreen.resetForCommand()
                        styledRenderer.reset()
                        isAlternateScreenActive = false
                        isApplicationCursorModeActive = false
                        activeBlockID = blockID
                        activeBlockCwd = nil
                        isReplayingCommand = true
                        emit(.replayCommandStarted(
                            blockID: blockID,
                            command: command
                        ))
                    }
                }
                if case .commandFinished = marker.kind {
                    activeBlockID = nil
                    pendingBlockID = nil
                    activeBlockCwd = nil
                    isReplayingCommand = false
                }
            }
        }
    }

    private func flushVisible(_ text: String) {
        guard !text.isEmpty, let activeBlockID else { return }
        consumeVisible(text, blockID: activeBlockID) { [weak self] snapshot in
            self?.emit(.snapshot(snapshot))
        }
    }

    private func consumeVisible(
        _ text: String,
        blockID: UUID,
        onSnapshot: (Snapshot) -> Void
    ) {
        let switches = Ansi.alternateScreenSwitchRanges(in: text)
        guard !switches.isEmpty else {
            consumeVisibleSegment(text, blockID: blockID, onSnapshot: onSnapshot)
            return
        }

        var cursor = text.startIndex
        for screenSwitch in switches {
            consumeVisibleSegment(
                String(text[cursor..<screenSwitch.range.lowerBound]),
                blockID: blockID,
                onSnapshot: onSnapshot
            )
            didSeeAlternateScreenSwitch = true
            consumeScreen(
                String(text[screenSwitch.range]),
                blockID: blockID,
                onSnapshot: onSnapshot
            )
            cursor = screenSwitch.range.upperBound
        }
        consumeVisibleSegment(String(text[cursor...]), blockID: blockID, onSnapshot: onSnapshot)
    }

    private func consumeVisibleSegment(
        _ text: String,
        blockID: UUID,
        onSnapshot: (Snapshot) -> Void
    ) {
        guard !text.isEmpty else { return }
        if isAlternateScreenActive || (usesPagerScreenRendering && !didSeeAlternateScreenSwitch) {
            consumeScreen(text, blockID: blockID, onSnapshot: onSnapshot)
        } else {
            let state = terminalScreen.process(text)
            isApplicationCursorModeActive = state.isApplicationCursorModeActive
            let rendered = styledRenderer.process(text, linkBaseDirectory: activeBlockCwd)
            onSnapshot(snapshot(
                blockID: blockID,
                plainText: rendered.plainText,
                attributedText: rendered.attributedText
            ))
        }
    }

    private func consumeScreen(
        _ text: String,
        blockID: UUID,
        onSnapshot: (Snapshot) -> Void
    ) {
        let state = terminalScreen.process(text)
        isAlternateScreenActive = state.isAlternateScreenActive
        isApplicationCursorModeActive = state.isApplicationCursorModeActive
        if state.isAlternateScreenActive || (usesPagerScreenRendering && !didSeeAlternateScreenSwitch) {
            onSnapshot(snapshot(
                blockID: blockID,
                plainText: state.text,
                attributedText: state.attributedText
            ))
        } else {
            let rendered = styledRenderer.process("", linkBaseDirectory: activeBlockCwd)
            onSnapshot(snapshot(
                blockID: blockID,
                plainText: rendered.plainText,
                attributedText: rendered.attributedText
            ))
        }
    }

    private func snapshot(
        blockID: UUID,
        plainText: String,
        attributedText: NSAttributedString
    ) -> Snapshot {
        Snapshot(
            blockID: blockID,
            plainText: plainText,
            attributedText: attributedText,
            isAlternateScreenActive: isAlternateScreenActive,
            isApplicationCursorModeActive: isApplicationCursorModeActive
        )
    }

    static func alternateScreenTranscriptSelfTest() -> Bool {
        func finalSnapshot(for text: String) -> Snapshot? {
            let processor = TerminalOutputProcessor()
            let blockID = UUID()
            var last: Snapshot?
            processor.consumeVisible(text, blockID: blockID) { snapshot in
                last = snapshot
            }
            return last
        }

        return finalSnapshot(for: "before\n\u{1B}[?1049heditor text\u{1B}[?1049lafter\n")?.plainText == "before\nafter\n"
            && finalSnapshot(for: "\u{1B}[?1049heditor text\u{1B}[?1049l")?.plainText == ""
            && finalSnapshot(for: "\u{1B}[?1h\u{1B}=\u{1B}[?1049hpager")?.isApplicationCursorModeActive == true
    }

    static func terminalSizeProbeSelfTest() -> Bool {
        TerminalOutputProcessor().terminalResponses(in: "\u{1B}[999;999f\u{1B}[6n")
            .contains("\u{1B}[30;100R")
    }

    static func inputFeedbackPrioritySelfTest() -> Bool {
        let processor = TerminalOutputProcessor()
        guard processor.queue.sync(execute: { !processor.consumeInputFeedbackPriority() }) else {
            return false
        }
        processor.prioritizeNextOutputForInput()
        return processor.queue.sync {
            processor.consumeInputFeedbackPriority()
                && !processor.consumeInputFeedbackPriority()
        }
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }

    private func terminalResponses(in text: String) -> [String] {
        var responses: [String] = []
        if text.contains("\u{1B}]10;?\u{7}") || text.contains("\u{1B}]10;?\u{1B}\\") {
            responses.append("\u{1B}]10;rgb:ffff/ffff/ffff\u{1B}\\")
        }
        if text.contains("\u{1B}]11;?\u{7}") || text.contains("\u{1B}]11;?\u{1B}\\") {
            responses.append("\u{1B}]11;rgb:0000/0000/0000\u{1B}\\")
        }
        if text.contains("\u{1B}[6n") {
            let position = text.contains("\u{1B}[999;999f") || text.contains("\u{1B}[999;999H")
                ? (rows, cols)
                : (1, 1)
            responses.append("\u{1B}[\(position.0);\(position.1)R")
        }
        return responses
    }
}

private final class SessionCandidateButton: NSControl {
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

    init(sessionRef: SessionRef, title: String, subtitle: String?, metadata: String) {
        self.sessionRef = sessionRef
        self.sessionID = sessionRef.sessionID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.clear.cgColor
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        iconView.image = Bundle.main.image(forResource: NSImage.Name("session-icon"))
        iconView.image?.isTemplate = true
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
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.maximumNumberOfLines = 1
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

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
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
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.modifierFlags.contains(.control), let menu {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        guard let action else { return }
        sendAction(action, to: target)
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

private final class SessionHeaderAddButton: NSButton {
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
            : TahoeGlassPalette.titleTextActive.withAlphaComponent(0.5)
        needsDisplay = true
    }
}

private final class SessionCandidateRowView: NSView {
    private enum Metrics {
        static let columnCount = 4
        static let spacing: CGFloat = 10
        static let height: CGFloat = 82
    }

    private let buttons: [SessionCandidateButton]

    init(buttons: [SessionCandidateButton]) {
        self.buttons = buttons
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
        let availableWidth = max(0, bounds.width - Metrics.spacing * CGFloat(Metrics.columnCount - 1))
        let columnWidth = floor(availableWidth / CGFloat(Metrics.columnCount))

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

@MainActor
private final class TerminalTab {
    let id = UUID()
    var sessionRef: SessionRef
    var sessionID: String {
        get { sessionRef.sessionID }
        set { sessionRef.sessionID = newValue }
    }
    var session: any TerminalSession
    let commandLifecycle: CommandLifecycle
    let outputProcessor = TerminalOutputProcessor()
    let rootView = NSView()
    let scrollView = NSScrollView()
    let stackView = NSStackView()
    let sessionPickerView = SessionPickerView()
    let sessionPickerStack = NSStackView()
    let inputView = CommandInputTextView(frame: .zero)
    let statusLineStack = NSStackView()
    let statusLabel = NSTextField(labelWithString: "Starting shell...")
    let commandSeparator = SeparatorView()
    let commandBarView = NSView()
    let findCloseButton = FindCloseButton(frame: .zero)
    let completionPendingLine = NSView()
    let ptyPassthroughView = PtyPassthroughView(frame: .zero)
    var title: String

    var scrollBottomToCommandBarConstraint: NSLayoutConstraint?
    var scrollBottomToRootConstraint: NSLayoutConstraint?
    var sessionPickerHeightConstraint: NSLayoutConstraint?

    var blocks: [TerminalBlock] { commandLifecycle.state.blocks }
    var blockViews: [UUID: BlockView] = [:]
    var pendingBlockViewUpdates = Set<UUID>()
    var isBlockViewUpdateScheduled = false
    var activeBlockID: UUID? { commandLifecycle.state.activeBlockID }
    var pendingBlockID: UUID? { commandLifecycle.state.pendingBlockID }
    var currentCwd: String { commandLifecycle.state.currentCwd }
    var isScrollToBottomScheduled = false
    var isShellReady: Bool { commandLifecycle.state.isShellReady }
    var isReplayingHistory: Bool { commandLifecycle.state.isReplayingHistory }
    var hasExited: Bool { commandLifecycle.state.hasExited }
    var isTerminalControlActive = false
    var isAlternateScreenActive: Bool { commandLifecycle.state.isAlternateScreenActive }
    var isApplicationCursorModeActive: Bool { commandLifecycle.state.isApplicationCursorModeActive }
    var runningElapsedTimer: Timer?
    var ttyModeTimer: Timer?
    var commandHistory: [String] { commandLifecycle.state.commandHistory }
    var hostHistoryOptOutBlockIDs = Set<UUID>()
    var isFindMode = false
    var findCommandDraft = ""
    var findQuery = ""
    var findResults: [FindResult] = []
    var findResultIndex: Int?
    var canReplaceFreshSession = false
    var createdAt: Date
    var commandCount: Int { commandLifecycle.state.commandCount }

    init(
        title: String,
        delegate: NSTextViewDelegate,
        sessionRef: SessionRef = .local(UUID().uuidString),
        createdAt: Date = Date(),
        commandCount: Int = 0,
        commandHistory: [String] = []
    ) {
        self.sessionRef = sessionRef
        switch sessionRef.location {
        case .relayMac:
            self.session = RelayTerminalSession(sessionRef: sessionRef)
        case .local, .sshHost:
            self.session = PtySession(sessionRef: sessionRef)
        }
        self.title = title
        self.createdAt = createdAt
        self.commandLifecycle = CommandLifecycle(
            cwd: FileManager.default.homeDirectoryForCurrentUser.path,
            commandCount: commandCount,
            commandHistory: commandHistory
        )
        buildView(delegate: delegate)
    }

    private func buildView(delegate: NSTextViewDelegate) {
        rootView.translatesAutoresizingMaskIntoConstraints = false

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
        scrollView.translatesAutoresizingMaskIntoConstraints = false

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
        inputView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 96)
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
        inputView.setAccessibilityLabel("Portal Terminal command input")

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
        commandBarView.layer?.backgroundColor = TahoeGlassPalette.commandTint.cgColor
        commandBarView.translatesAutoresizingMaskIntoConstraints = false
        findCloseButton.isHidden = true
        findCloseButton.translatesAutoresizingMaskIntoConstraints = false
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
        commandBarView.addSubview(findCloseButton)
        commandBarView.addSubview(inputScroll)
        commandBarView.addSubview(completionPendingLine)

        rootView.addSubview(scrollView)
        rootView.addSubview(sessionPickerView)
        rootView.addSubview(commandSeparator)
        rootView.addSubview(commandBarView)
        rootView.addSubview(ptyPassthroughView)

        scrollBottomToCommandBarConstraint = scrollView.bottomAnchor.constraint(equalTo: sessionPickerView.topAnchor)
        scrollBottomToRootConstraint = scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        scrollBottomToRootConstraint?.isActive = false
        sessionPickerHeightConstraint = sessionPickerView.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: rootView.topAnchor),
            scrollBottomToCommandBarConstraint!,

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
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),

            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.topAnchor.constraint(greaterThanOrEqualTo: documentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),

            commandBarView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            commandBarView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            commandBarView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            statusLineStack.leadingAnchor.constraint(equalTo: commandBarView.leadingAnchor, constant: 12),
            statusLineStack.trailingAnchor.constraint(
                lessThanOrEqualTo: findCloseButton.leadingAnchor,
                constant: -8
            ),
            statusLineStack.topAnchor.constraint(equalTo: commandBarView.topAnchor, constant: 8),
            findCloseButton.topAnchor.constraint(equalTo: commandBarView.topAnchor, constant: 4),
            findCloseButton.trailingAnchor.constraint(equalTo: commandBarView.trailingAnchor, constant: -8),
            findCloseButton.widthAnchor.constraint(equalToConstant: 28),
            findCloseButton.heightAnchor.constraint(equalToConstant: 28),

            inputScroll.leadingAnchor.constraint(equalTo: commandBarView.leadingAnchor),
            inputScroll.trailingAnchor.constraint(equalTo: commandBarView.trailingAnchor),
            inputScroll.topAnchor.constraint(equalTo: statusLineStack.bottomAnchor, constant: 4),
            inputScroll.bottomAnchor.constraint(equalTo: commandBarView.bottomAnchor),
            inputScroll.heightAnchor.constraint(equalToConstant: 64),

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

final class TerminalViewController: NSViewController, NSTextViewDelegate {
    private typealias StoredTab = SessionCatalog.Record

    private struct TerminalGridSize {
        let rows: UInt16
        let cols: UInt16
    }

    private let selfTestCommand: String?
    private let sessionCatalog: SessionCatalog
    private var windowID: String { sessionCatalog.windowID }
    private let restoresPersistedWindow: Bool
    private var didRunSelfTest = false
    private var initialCommands: [UUID: String] = [:]
    private var tabs: [TerminalTab] = []
    private var closedTabs: [StoredTab] { sessionCatalog.closedTabs }
    private var isKillingClosedTabs = false
    private var killingSessionRefs = Set<SessionRef>()
    private var activeTabID: UUID?
    private var tabButtons: [UUID: TitleTabButton] = [:]
    private var sessionPickerCandidatesByTab: [UUID: [SessionRef: SessionPickerCandidate]] = [:]
    private var sessionPickerModelsByTab: [UUID: SessionPickerModel] = [:]
    var onInstallStagedUpdate: (() -> Void)?
    var backgroundBlurEffect = BackgroundBlurEffect.preferred {
        didSet {
            guard isViewLoaded else { return }
            (view as? TahoeGlassRootView)?.backgroundBlurEffect = backgroundBlurEffect
        }
    }

    private let titleTabStack = TitleTabStackView()
    private let titleTabBorderView = TitleTabBorderView()
    private let newTabButton = TitleAddButton(frame: .zero)
    private let updateButton = TitleUpdateButton(frame: .zero)
    private let contentContainer = NSView()
    private let resizeTooltipView = ResizeMetricsTooltipView()
    private let completionEngine = VaulttyCompletionEngine()
    private let completionQueue = DispatchQueue(label: "com.automicvault.vaultty.completion", qos: .userInitiated)
    private let gitStateProvider = GitDirectoryStateProvider()
    private let gitStateQueue = DispatchQueue(label: "com.automicvault.vaultty.git-state", qos: .utility)
    private let sessionCleanupQueue = DispatchQueue(label: "com.automicvault.vaultty.session-cleanup", qos: .utility)
    private let completionPopup = CompletionPopupController()
    private var completionRequestSerial = 0
    private var completionCancellation: CompletionCancellation?
    private var pendingCompletionIndicatorTabID: UUID?
    private var deferredCompletionAcceptanceSerial: Int?
    private var activeCompletionRange: NSRange?
    private var activeCompletionCommonPrefix: String?
    private var activeCompletionMode: CompletionRequestMode?
    private var canInsertCommandSeparator = false
    private var isApplyingCompletion = false
    private var isCompletionInteractionArmed = false
    private var isShowingResizeTooltip = false
    private var tabMouseDownMonitor: Any?
    private var sessionPickerMouseDownMonitor: Any?
    private var commandFocusMonitor: Any?
    private var updateButtonWidthConstraint: NSLayoutConstraint?
    private let blockViewRenderDelay: TimeInterval = 1.0 / 12.0
    private let interactiveBlockViewRenderDelay: TimeInterval = 1.0 / 60.0
    private let fallbackDisplayRefreshRate = 60
    private static let didRunPassthroughRoutingSelfTest: Void = {
        assert(PtyPassthroughView.passthroughRoutingSelfTest())
        assert(TerminalOutputProcessor.alternateScreenTranscriptSelfTest())
        assert(TerminalOutputProcessor.terminalSizeProbeSelfTest())
        assert(TerminalOutputProcessor.inputFeedbackPrioritySelfTest())
        assert(SessionPickerView.headerButtonHitTestingSelfTest())
        assert(SessionPickerView.keyboardNavigationSelfTest())
        assert(CompletionPopupController.selectionSelfTest())
        assert(CommandInputTextView.completionPreviewPreservesCaretSelfTest())
        assert(VaulttyCompletionEngine.historyMergePrefixSelfTest())
        assert(ShellCompletionParser.midTokenReplacementRangeSelfTest())
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

    private enum TabClickTarget {
        case select(UUID)
        case close(UUID)
    }

    init(
        selfTestCommand: String? = nil,
        windowID: String = UUID().uuidString,
        restoresPersistedWindow: Bool = true
    ) {
        _ = Self.didRunPassthroughRoutingSelfTest
        self.selfTestCommand = selfTestCommand
        self.sessionCatalog = SessionCatalog(url: Self.sessionStateURL(), windowID: windowID)
        self.restoresPersistedWindow = restoresPersistedWindow
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        _ = Self.didRunPassthroughRoutingSelfTest
        self.selfTestCommand = nil
        self.sessionCatalog = SessionCatalog(url: Self.sessionStateURL(), windowID: UUID().uuidString)
        self.restoresPersistedWindow = true
        super.init(coder: coder)
    }

    override func loadView() {
        let rootView = TahoeGlassRootView()
        rootView.backgroundBlurEffect = backgroundBlurEffect
        rootView.onLayout = { [weak self] in
            self?.handleRootLayout()
        }
        rootView.onUpdateButtonMouseDown = { [weak self] in
            self?.updateButton.triggerAction()
        }
        view = rootView

        titleTabStack.orientation = .horizontal
        titleTabStack.spacing = 0
        titleTabStack.alignment = .centerY
        titleTabStack.distribution = .fill
        titleTabStack.translatesAutoresizingMaskIntoConstraints = false

        newTabButton.target = self
        newTabButton.action = #selector(newTab(_:))
        updateButton.target = self
        updateButton.action = #selector(installStagedUpdate(_:))
        updateButton.isHidden = true
        titleTabBorderView.tabStack = titleTabStack

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        resizeTooltipView.isHidden = true

        view.addSubview(titleTabStack)
        view.addSubview(titleTabBorderView)
        view.addSubview(updateButton)
        view.addSubview(contentContainer)
        view.addSubview(resizeTooltipView)
        titleTabStack.addArrangedSubview(newTabButton)
        updateTitleSegmentCornerMasks()

        let updateButtonWidthConstraint = updateButton.widthAnchor.constraint(equalToConstant: 0)
        self.updateButtonWidthConstraint = updateButtonWidthConstraint

        NSLayoutConstraint.activate([
            titleTabStack.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: TahoeGlassPalette.titleTabLeadingInset
            ),
            titleTabStack.trailingAnchor.constraint(
                lessThanOrEqualTo: updateButton.leadingAnchor,
                constant: -12
            ),
            titleTabStack.topAnchor.constraint(
                equalTo: view.topAnchor,
                constant: TahoeGlassPalette.titleTabTopInset
            ),
            titleTabStack.heightAnchor.constraint(equalToConstant: TahoeGlassPalette.titleTabHeight),

            titleTabBorderView.leadingAnchor.constraint(equalTo: titleTabStack.leadingAnchor),
            titleTabBorderView.trailingAnchor.constraint(equalTo: titleTabStack.trailingAnchor),
            titleTabBorderView.topAnchor.constraint(equalTo: titleTabStack.topAnchor),
            titleTabBorderView.bottomAnchor.constraint(equalTo: titleTabStack.bottomAnchor),

            newTabButton.heightAnchor.constraint(equalToConstant: TahoeGlassPalette.titleTabHeight),
            newTabButton.widthAnchor.constraint(equalTo: newTabButton.heightAnchor),

            updateButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            updateButton.topAnchor.constraint(
                equalTo: view.topAnchor,
                constant: (TahoeGlassPalette.titleBarHeight - TitleUpdateButton.visibleHeight) / 2
            ),
            updateButton.heightAnchor.constraint(equalToConstant: TitleUpdateButton.visibleHeight),
            updateButtonWidthConstraint,

            contentContainer.leadingAnchor.constraint(
                equalTo: view.leadingAnchor
            ),
            contentContainer.trailingAnchor.constraint(
                equalTo: view.trailingAnchor
            ),
            contentContainer.topAnchor.constraint(
                equalTo: view.topAnchor,
                constant: TahoeGlassPalette.titleContentTop
            ),
            contentContainer.bottomAnchor.constraint(
                equalTo: view.bottomAnchor
            )
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
        installTabMouseDownMonitor()
        installSessionPickerMouseDownMonitor()
        installCommandFocusMonitor()
    }

    deinit {
        if let tabMouseDownMonitor {
            NSEvent.removeMonitor(tabMouseDownMonitor)
        }
        if let sessionPickerMouseDownMonitor {
            NSEvent.removeMonitor(sessionPickerMouseDownMonitor)
        }
        if let commandFocusMonitor {
            NSEvent.removeMonitor(commandFocusMonitor)
        }
        stopAllSessions()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        windowDidAttach()
    }

    func windowDidAttach() {
        if let tab = activeTab {
            focusInput(for: tab)
        }
    }

    func windowDidBecomeActive() {
        restoreCommandFocusIfNeeded()
        refreshVisibleCommandBarGitStatus()
    }

    func stopAllSessions() {
        for tab in tabs {
            let shouldKillUnpersistedSession = !shouldPersistSession(tab) && !isSessionVisibleOutsideTab(tab)
            stopRunningElapsedUpdates(for: tab)
            stopTtyModePolling(for: tab)
            if shouldKillUnpersistedSession {
                tab.session.kill()
            } else {
                tab.session.stop()
            }
        }
    }

    func setUpdateStaged(_ isStaged: Bool) {
        if !isStaged {
            updateButton.isInstalling = false
            updateButton.alphaValue = 1
        }
        updateButton.isHidden = !isStaged
        updateButton.isEnabled = isStaged
        updateButton.toolTip = isStaged ? "Install staged update" : nil
        updateButtonWidthConstraint?.constant = isStaged ? TitleUpdateButton.visibleWidth : 0
        view.needsLayout = true
    }

    func setUpdateInstallInProgress(_ isInstalling: Bool) {
        updateButton.isInstalling = isInstalling
        updateButton.isEnabled = !isInstalling
        updateButton.toolTip = isInstalling ? "Installing update" : "Install staged update"
        updateButtonWidthConstraint?.constant = isInstalling
            ? TitleUpdateButton.installingWidth
            : TitleUpdateButton.visibleWidth
    }

    func clearCommandHistory(_ sender: Any?) {
        guard let tab = activeTab else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear command history on this host?"
        alert.informativeText = "This permanently removes successful Vaultty commands stored on the active host. Session Up/Down history is unchanged."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        dismissCompletion()
        let location = tab.sessionRef.location
        let relayProvider = (tab.session as? RelayTerminalSession)?.completionProvider
        completionQueue.async { [weak self] in
            guard let self else { return }
            let cleared = completionEngine.clearHistory(
                location: location,
                relayProvider: relayProvider
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
        updateTitleSegmentCornerMasks()
        updateActiveTabCutoutFrame()
        if let rootView = view as? TahoeGlassRootView {
            rootView.updateButtonFrame = updateButton.isHidden
                ? nil
                : updateButton.convert(updateButton.bounds, to: rootView)
        }
        titleTabBorderView.needsDisplay = true
        for tab in tabs {
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
                isCompletionInteractionArmed = false
                completionPopup.clearSelection()
                tab.inputView.clearMutedCompletionPreview()
                return false
            }
            if commandSelector == #selector(NSResponder.moveRight(_:)) {
                if completionPopup.selectedSuggestion != nil {
                    acceptSelectedCompletion(in: tab)
                    return true
                }
                isCompletionInteractionArmed = true
                if let suggestion = completionPopup.selectNext() {
                    renderCompletionPreview(suggestion, in: tab)
                }
                return true
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                isCompletionInteractionArmed = true
                if let suggestion = completionPopup.selectPrevious() {
                    renderCompletionPreview(suggestion, in: tab)
                }
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                isCompletionInteractionArmed = true
                if let suggestion = completionPopup.selectNext() {
                    renderCompletionPreview(suggestion, in: tab)
                }
                return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                isCompletionInteractionArmed = true
                if deferCompletionAcceptanceUntilPendingRequestCompletes(in: tab) {
                    return true
                }
                if completionPopup.selectedSuggestion == nil {
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
                isCompletionInteractionArmed = true
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
            isCompletionInteractionArmed = true
            requestCompletion(in: tab, mode: .explicit)
            return true
        }
        if commandSelector == #selector(NSResponder.moveRight(_:)) {
            let selection = textView.selectedRange()
            if selection.length == 0,
               selection.location == (textView.string as NSString).length {
                isCompletionInteractionArmed = true
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
            isCompletionInteractionArmed = false
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

    @objc func newTab(_ sender: Any?) {
        createTab()
    }

    func newRemoteTab(host: SSHHostRecord) {
        Task {
            do {
                let defaults = try await Task.detached {
                    try PtySession.remoteSessionDefaults(host: host)
                }.value
                createTab(
                    workingDirectory: URL(fileURLWithPath: defaults.homeDirectory),
                    sessionRef: SessionRef(
                        location: .sshHost(host.id),
                        sessionID: UUID().uuidString,
                        hostName: host.alias
                    ),
                    shellPath: defaults.shellPath,
                    showsSessionPicker: false
                )
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "Could not open a tab on \(host.alias)"
                alert.runModal()
            }
        }
    }

    @objc private func installStagedUpdate(_ sender: Any?) {
        onInstallStagedUpdate?()
    }

    func newTab(at directoryURL: URL) {
        createTab(workingDirectory: directoryURL)
    }

    func newTab(at directoryURL: URL, running command: String) {
        createTab(workingDirectory: directoryURL, initialCommand: command)
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

    @objc func selectPreviousTab(_ sender: Any?) {
        activateAdjacentTab(offset: -1)
    }

    @objc func selectNextTab(_ sender: Any?) {
        activateAdjacentTab(offset: 1)
    }

    @objc private func selectTab(_ sender: TitleTabButton) {
        activateTab(sender.tabID)
    }

    @objc func closeActiveTabOrWindow(_ sender: Any?) {
        guard let activeTabID else {
            view.window?.performClose(sender)
            return
        }
        closeTab(withID: activeTabID)
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        guard let stored = sessionCatalog.popLastClosed() else {
            NSSound.beep()
            return
        }
        createTab(
            workingDirectory: URL(fileURLWithPath: stored.cwd),
            sessionRef: sessionRef(from: stored),
            title: stored.title,
            createdAt: stored.createdAt ?? Date(),
            commandCount: stored.commandCount ?? 0,
            commandHistory: stored.commandHistory ?? [],
            showsSessionPicker: false
        )
        persistSessionState()
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
        tab.inputView.setAccessibilityLabel("Portal Terminal history find")
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
        tab.commandBarView.layer?.backgroundColor = TahoeGlassPalette.commandTint.cgColor
        tab.findCloseButton.isHidden = true
        tab.inputView.setAccessibilityLabel("Portal Terminal command input")
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

    @objc private func closeTab(_ sender: NSButton) {
        guard let button = sender.superview as? TitleTabButton else { return }
        closeTab(withID: button.tabID)
    }

    @discardableResult
    private func closeTab(withID id: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              let button = tabButtons[id]
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
        stopTtyModePolling(for: tab)
        if !shouldPersistTab && !isVisibleOutsideTab {
            tab.session.kill()
        } else {
            tab.session.stop()
        }
        let wasActive = activeTabID == tab.id
        tab.rootView.removeFromSuperview()
        titleTabStack.removeArrangedSubview(button)
        button.removeFromSuperview()
        tabButtons.removeValue(forKey: tab.id)
        tabs.remove(at: index)

        guard !tabs.isEmpty else {
            activeTabID = nil
            layoutTabStripBeforeMeasuringSelection()
            updateActiveTabCutoutFrame()
            persistSessionState()
            view.window?.performClose(nil)
            return true
        }

        if wasActive {
            let nextIndex = min(index, tabs.count - 1)
            activateTab(tabs[nextIndex].id, tabStripLayoutChanged: true)
        } else {
            layoutTabStripBeforeMeasuringSelection()
            updateActiveTabCutoutFrame()
        }
        persistSessionState()
        configureSessionPickerIfPossible()
        return true
    }

    private var activeTab: TerminalTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    private func restoreSessionState() {
        let restoration = sessionCatalog.restore(restoresPersistedWindow: restoresPersistedWindow)
        let tabsToRestore = restoration.tabs

        if tabsToRestore.isEmpty {
            createTab()
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
            commandHistory: storedTab.commandHistory ?? [],
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
            && SessionDaemonIdentity(externalSessionID: tab.sessionID).isPersistable
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
            runningCommand: runningCommand(in: tab),
            commandHistory: tab.commandHistory
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
            .appendingPathComponent("Vaultty", isDirectory: true)
            .appendingPathComponent("sessions.json", isDirectory: false)
    }

    private func createTab(
        workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        sessionRef: SessionRef = .local(UUID().uuidString),
        title: String? = nil,
        createdAt: Date = Date(),
        commandCount: Int = 0,
        commandHistory: [String] = [],
        initialCommand: String? = nil,
        shellPath: String? = nil,
        showsSessionPicker: Bool = true,
        activates: Bool = true,
        persists: Bool = true
    ) {
        let directoryURL = workingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let directoryPath = directoryURL.path
        let tab = TerminalTab(
            title: title ?? titleForDirectory(directoryPath),
            delegate: self,
            sessionRef: sessionRef,
            createdAt: createdAt,
            commandCount: commandCount,
            commandHistory: commandHistory
        )
        tab.commandLifecycle.apply(.cwdChanged(directoryPath))
        tab.findCloseButton.target = self
        tab.findCloseButton.action = #selector(closeFindMode(_:))
        setCommandBarStatusText("Starting shell...", in: tab)
        tab.rootView.isHidden = !activates
        tabs.append(tab)
        if let initialCommand {
            initialCommands[tab.id] = initialCommand
        }
        configureSession(for: tab)
        configureInterruptHandling(for: tab)
        installTabView(tab)
        installTabButton(tab)
        if activates {
            activateTab(tab.id, tabStripLayoutChanged: true, persists: persists)
        } else {
            layoutTabStripBeforeMeasuringSelection()
        }
        startShell(for: tab, workingDirectory: directoryURL, shellPath: shellPath)
        if showsSessionPicker {
            configureSessionPicker(for: tab)
        }
        if persists {
            persistSessionState()
        }
    }

    private func configureSessionPicker(for tab: TerminalTab) {
        let model = SessionPickerModel()
        sessionPickerModelsByTab[tab.id]?.invalidate()
        sessionPickerModelsByTab[tab.id] = model
        let initial = localSessionCandidates(excluding: tab).filter {
            if case .sshHost = $0.sessionRef.location { return false }
            return true
        }
        let excluded = Set(tabs.map(\.sessionRef))
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
            loadRelay: { [weak self] in
                guard let self else { return nil }
                return await self.relaySessionCandidates()
            },
            isAvailable: { [weak self] sessionRef in
                guard let self else { return false }
                return !self.killingSessionRefs.contains(sessionRef)
                    && !self.sessionCatalog.isExited(sessionRef)
            },
            onUpdate: { [weak self] snapshot in
                guard let self,
                      let tab = self.tabs.first(where: { $0.id == tabID }),
                      tab.commandCount == 0
                else {
                    return
                }
                self.renderSessionPicker(snapshot, for: tab)
            }
        )
    }

    private func renderSessionPicker(_ snapshot: SessionPickerSnapshot, for tab: TerminalTab) {
        guard !snapshot.sections.isEmpty else {
            tab.canReplaceFreshSession = true
            tab.sessionPickerView.clearSelection()
            sessionPickerCandidatesByTab[tab.id] = [:]
            tab.sessionPickerView.isHidden = true
            tab.sessionPickerHeightConstraint?.constant = 0
            for view in tab.sessionPickerStack.arrangedSubviews {
                tab.sessionPickerStack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            tab.rootView.needsLayout = true
            return
        }

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
                icon.contentTintColor = TahoeGlassPalette.titleTextActive.withAlphaComponent(0.34)
                headerStack.addArrangedSubview(icon)
            }
            headerStack.addArrangedSubview(header)
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
                let emptyLabel = NSTextField(labelWithString: "No active sessions")
                emptyLabel.font = .systemFont(ofSize: 11, weight: .regular)
                emptyLabel.textColor = TahoeGlassPalette.titleTextActive.withAlphaComponent(0.22)
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
                runningCommand: session.runningCommand,
                commandHistory: session.commandHistory,
                action: .attach,
                attachedClientCount: session.attachedClientCount
            )
        }
    }

    private func relaySessionCandidates() async -> [SessionPickerCandidate]? {
        guard let endpoint = try? MacRemoteAccessController.relayEndpoint(),
              let key = try? ICloudKeychainRootKey().loadOrCreate(),
              let client = try? RelayCatalogClient(endpoint: endpoint, rootKeyData: key),
              let data = try? await client.load(),
              let catalog = try? JSONDecoder().decode(RemoteCatalog.self, from: data)
        else {
            return nil
        }
        let now = Date()
        var candidates: [SessionPickerCandidate] = []
        var seenSessionRefs = Set<SessionRef>()
        let localMacID = MacRemoteAccessController.macID()
        for mac in catalog.macs where
            mac.id != localMacID &&
            mac.online &&
            now.timeIntervalSince(mac.lastSeen) < 10
        {
            let location = SessionLocation.relayMac(mac.id)
            let newSessionRef = SessionRef(
                location: location,
                sessionID: UUID().uuidString,
                hostName: mac.name
            )
            candidates.append(SessionPickerCandidate(
                sessionRef: newSessionRef,
                hostTitle: mac.name,
                title: "New session",
                cwd: mac.homeDirectory ?? "/",
                isClosed: false,
                createdAt: nil,
                commandCount: 0,
                runningCommand: nil,
                commandHistory: [],
                action: .createRelay
            ))
            for session in mac.sessions {
                let sessionRef = SessionRef(
                    location: location,
                    sessionID: session.sessionID,
                    hostName: mac.name
                )
                guard seenSessionRefs.insert(sessionRef).inserted else { continue }
                candidates.append(SessionPickerCandidate(
                    sessionRef: sessionRef,
                    hostTitle: mac.name,
                    title: session.title,
                    cwd: session.cwd,
                    isClosed: false,
                    createdAt: session.createdAt,
                    commandCount: session.commandCount,
                    runningCommand: session.runningCommand,
                    commandHistory: [],
                    action: .attach,
                    attachedClientCount: session.attachedClientCount
                ))
            }
        }
        return candidates
    }

    private func hostname(for sessionRef: SessionRef) -> String? {
        switch sessionRef.location {
        case .local:
            return nil
        case .sshHost(let hostID):
            guard let host = PtySession.loadSSHHosts().hosts.first(where: { $0.id == hostID })
            else { return nil }
            return host.hostname.isEmpty ? host.alias : host.hostname
        case .relayMac(let macID):
            return sessionRef.hostName ?? macID
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
        case .createRelay:
            replaceFreshSession(
                in: tab,
                with: candidate,
                createsRelaySession: true
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
                if case .relayMac = sessionRef.location {
                    try await RelayTerminalSession.killDetached(sessionRef)
                } else {
                    try await Task.detached {
                        try PtySession.killDetachedSession(sessionRef: sessionRef)
                    }.value
                }
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
        shellPath: String? = nil,
        createsRelaySession: Bool = false
    ) {
        tab.session.kill()

        hideSessionPicker(for: tab)
        clearCommandInput(in: tab)
        tab.sessionRef = candidate.sessionRef
        switch candidate.sessionRef.location {
        case .relayMac:
            tab.session = RelayTerminalSession(
                sessionRef: candidate.sessionRef,
                createsSession: createsRelaySession
            )
        case .local, .sshHost:
            tab.session = PtySession(sessionRef: candidate.sessionRef)
        }
        tab.title = candidate.title
        tab.createdAt = candidate.createdAt ?? Date()
        tab.commandLifecycle.apply(.replaceSession(
            cwd: candidate.cwd,
            commandCount: candidate.commandCount,
            commandHistory: candidate.commandHistory
        ))
        resetTranscriptViews(for: tab)
        setCommandBarStatusText("Rejoining session...", in: tab)
        tab.isTerminalControlActive = false
        tab.outputProcessor.resetForReplay()
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

    private func installTabButton(_ tab: TerminalTab) {
        let standardTitle = standardTabTitle(tab.title, in: tab)
        tab.title = displayTabTitle(standardTitle, in: tab)
        let button = TitleTabButton(tabID: tab.id, title: standardTitle)
        button.updateTitle(
            standardTitle,
            hostPrefix: hostname(for: tab.sessionRef),
            detail: detailForDirectory(tab.currentCwd)
        )
        button.target = self
        button.action = #selector(selectTab(_:))
        button.configureClose(target: self, action: #selector(closeTab(_:)))
        updateRunningIndicator(for: tab, button: button)
        tabButtons[tab.id] = button
        titleTabStack.insertArrangedSubview(button, at: max(0, titleTabStack.arrangedSubviews.count - 1))
        updateTitleSegmentCornerMasks()
        NSLayoutConstraint.activate(button.widthConstraints + [
            button.heightAnchor.constraint(equalToConstant: TahoeGlassPalette.titleTabHeight)
        ])
    }

    private func installTabMouseDownMonitor() {
        tabMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self,
                  event.window === self.view.window
            else {
                return event
            }

            guard let clickedTarget = self.tabClickTarget(atWindowPoint: event.locationInWindow) else {
                return event
            }

            switch clickedTarget {
            case .select(let id):
                self.activateTab(id)
            case .close(let id):
                _ = self.closeTab(withID: id)
            }
            return nil
        }
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
                  event.window === self.view.window
            else {
                return event
            }

            switch event.type {
            case .keyDown:
                if self.activeTab?.sessionPickerView.handleKeyEvent(event) == true {
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
            isCompletionInteractionArmed = true
            if let suggestion = completionPopup.selectNext() {
                renderCompletionPreview(suggestion, in: tab)
            }
        } else {
            isCompletionInteractionArmed = true
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
        guard let window = view.window else { return false }
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
            if view is BlockOutputTextView || view is SelectableBlockTextField {
                return true
            }
            current = view.superview
        }
        return false
    }

    private func tabClickTarget(atWindowPoint windowPoint: NSPoint) -> TabClickTarget? {
        for (id, button) in tabButtons {
            guard !button.isHidden, button.window != nil else { continue }
            let point = button.convert(windowPoint, from: nil)
            if button.bounds.contains(point) {
                return button.containsCloseButton(at: point) ? .close(id) : .select(id)
            }
        }
        return nil
    }

    private func activateTab(_ id: UUID, tabStripLayoutChanged: Bool = false, persists: Bool = true) {
        activeTabID = id
        for tab in tabs {
            tab.rootView.isHidden = tab.id != id
            tabButtons[tab.id]?.isSelectedTab = tab.id == id
        }
        if tabStripLayoutChanged {
            layoutTabStripBeforeMeasuringSelection()
        }
        updateActiveTabCutoutFrame()
        if let tab = activeTab {
            focusInput(for: tab)
            refreshVisibleCommandBarGitStatus(for: tab)
        }
        if persists {
            persistSessionState()
        }
    }

    private func activateAdjacentTab(offset: Int) {
        guard tabs.count > 1,
              let activeTabID,
              let currentIndex = tabs.firstIndex(where: { $0.id == activeTabID })
        else {
            return
        }

        let nextIndex = (currentIndex + offset + tabs.count) % tabs.count
        activateTab(tabs[nextIndex].id)
    }

    private func layoutTabStripBeforeMeasuringSelection() {
        guard view.window != nil else { return }
        updateTitleSegmentCornerMasks()
        titleTabStack.needsLayout = true
        titleTabBorderView.needsDisplay = true
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    private func updateTitleSegmentCornerMasks() {
        let visibleSegments = titleTabStack.arrangedSubviews.filter { !$0.isHidden }
        for segment in visibleSegments {
            let roundsLeading = segment === visibleSegments.first
            let roundsTrailing = segment === visibleSegments.last

            if let tabButton = segment as? TitleTabButton {
                tabButton.roundsLeadingTopCorner = roundsLeading
                tabButton.roundsTrailingTopCorner = roundsTrailing
            } else if let addButton = segment as? TitleAddButton {
                addButton.roundsLeadingTopCorner = roundsLeading
                addButton.roundsTrailingTopCorner = roundsTrailing
            }
        }
    }

    private func updateActiveTabCutoutFrame() {
        guard let rootView = view as? TahoeGlassRootView else { return }
        rootView.tabStripFrame = titleTabStack.convert(titleTabStack.bounds, to: rootView)
        guard let activeTabID,
              let button = tabButtons[activeTabID],
              button.superview != nil
        else {
            rootView.activeTabFrame = nil
            return
        }
        rootView.activeTabFrame = button.convert(button.bounds, to: rootView)
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
        tab.session.onOutput = { [weak outputProcessor = tab.outputProcessor] text in
            outputProcessor?.enqueueShellOutput(text)
        }
        tab.session.onHistoryOutput = { [weak self, weak tab] text in
            DispatchQueue.main.async { [weak self, weak tab] in
                guard let self, let tab else { return }
                tab.commandLifecycle.apply(.beginHistoryReplay)
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
            let exitChange = tab.commandLifecycle.apply(.shellExited(status: status, at: Date()))
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
                self.stopTtyModePolling(for: tab)
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
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.automicvault.vaultty"
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        env["TERM"] = "xterm-256color"
        env["TERM_PROGRAM"] = "Portal"
        env["TERM_PROGRAM_VERSION"] = appVersion
        env["LC_TERMINAL"] = "Portal"
        env["LC_TERMINAL_VERSION"] = appVersion
        env["__CFBundleIdentifier"] = bundleIdentifier
        env["VAULTTY"] = "1"
        env["PROMPT"] = ""
        env["RPROMPT"] = ""

        let initScript = """
            export VAULTTY=1
            export TERM=xterm-256color
            export TERM_PROGRAM=Portal
            export TERM_PROGRAM_VERSION=\(shellQuote(appVersion))
            export LC_TERMINAL=Portal
            export LC_TERMINAL_VERSION=\(shellQuote(appVersion))
            export __CFBundleIdentifier=\(shellQuote(bundleIdentifier))
            \(isSSHSession ? remoteCodeFunctionScript : "")
            cd \(shellQuote(workingDirectory.path))
            stty -echo
            PROMPT=''
            RPROMPT=''
            setopt no_prompt_cr 2>/dev/null || true
            printf '\\033]133;R;%s\\a' "$(pwd | base64)"

            """

        tab.session.onReady = { [weak self, weak tab] created in
            guard let self, let tab else { return }
            guard created else {
                tab.commandLifecycle.apply(.markNeedsShellInputReset)
                self.finishHistoryReplay(in: tab)
                return
            }
            tab.session.write(initScript, suppressEcho: true)
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

    private func bundledExecutablePath(named name: String) -> String? {
        let helpersURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: helpersURL.path) {
            return helpersURL.path
        }
        return Bundle.main.path(forResource: name, ofType: nil)
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
        showPendingCompletionIndicator(in: tab)
        var environment: [String: String]
        switch tab.sessionRef.location {
        case .local:
            environment = ProcessInfo.processInfo.environment
        case .sshHost, .relayMac:
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
            relayProvider: (tab.session as? RelayTerminalSession)?.completionProvider,
            includesHistory: mode == .history || (tab.inputView.string as NSString).length >= 2,
            historyOnly: mode == .history
        )

        completionQueue.async { [weak self] in
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
        let selectFirstSuggestion = result.suggestions.first.map { suggestion in
            if case .history = suggestion.kind { return false }
            return true
        } ?? false
        completionPopup.show(
            suggestions: result.suggestions,
            relativeTo: anchor,
            of: tab.commandBarView,
            resetSelection: mode != .explicit,
            selectFirstSuggestion: mode != .continuation && isCompletionInteractionArmed && selectFirstSuggestion
        )
        assert(mode != .continuation || completionPopup.selectedSuggestion == nil)
        let shouldRenderPreview = mode == .explicit || mode == .rightArrow || mode == .continuation
        if shouldRenderPreview, let suggestion = completionPopup.selectedSuggestion {
            renderCompletionPreview(suggestion, in: tab)
        }
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
        guard pendingCompletionIndicatorTabID == tab.id else { return false }
        deferredCompletionAcceptanceSerial = completionRequestSerial
        return true
    }

    private func completeFromPopup(in tab: TerminalTab, continuingDirectories: Bool = false) {
        if completionPopup.selectedSuggestion == nil {
            _ = completionPopup.selectNext()
        }
        if insertSharedCompletionPrefixIfAvailable(in: tab) {
            return
        }
        acceptSelectedCompletion(in: tab, continuingDirectories: continuingDirectories)
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
        isCompletionInteractionArmed = true
        renderCompletionPreview(suggestion, in: tab)
    }

    private func acceptCompletionSelection(_ suggestion: CompletionSuggestion) {
        guard let tab = activeTab else {
            dismissCompletion()
            return
        }
        isCompletionInteractionArmed = true
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
        guard let range = suggestion.replacementRange ?? activeCompletionRange else { return }
        replace(range: range, with: suggestion.insertText, in: tab)
        if dismissAfterApplying {
            dismissCompletion()
        } else {
            updateCompletionAnchor(for: tab)
        }
    }

    private func renderCompletionPreview(_ suggestion: CompletionSuggestion, in tab: TerminalTab) {
        guard let replacementRange = suggestion.replacementRange ?? activeCompletionRange else {
            tab.inputView.clearMutedCompletionPreview()
            return
        }
        tab.inputView.renderCompletionPreview(suggestion, replacementRange: replacementRange)
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
        isCompletionInteractionArmed = false
        completionPopup.dismiss()
        completionCancellation?.cancel()
        completionCancellation = nil
        completionRequestSerial += 1
    }

    private func showPendingCompletionIndicator(in tab: TerminalTab) {
        clearPendingCompletionIndicator()
        pendingCompletionIndicatorTabID = tab.id
        tab.completionPendingLine.isHidden = false
    }

    private func clearPendingCompletionIndicator() {
        guard let tabID = pendingCompletionIndicatorTabID else { return }
        tabs.first { $0.id == tabID }?.completionPendingLine.isHidden = true
        pendingCompletionIndicatorTabID = nil
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

    private func submitCommand(in tab: TerminalTab) {
        guard tab.isShellReady, !tab.isReplayingHistory else { return }
        dismissCompletion()
        hideSessionPicker(for: tab)
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
        startTtyModePolling(for: tab)
        startRunningElapsedUpdates(for: tab)

        let encodedCommand = command.data(using: .utf8)?.base64EncodedString() ?? ""
        let script = shellLineResetSequence + shellInputResetPrefixIfNeeded(in: tab) + "__vaultty_cmd=\(shellQuote(command)); __vaultty_command_b64=\(shellQuote(encodedCommand)); printf '\\033]133;C;%s\\a' \"$__vaultty_command_b64\"; eval \"$__vaultty_cmd\"; __vaultty_status=$?; printf '\\033]133;P;%s\\a' \"$(pwd | base64)\"; printf '\\033]133;D;%s\\a' \"$__vaultty_status\"\n"
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
        tab.inputView.scrollRangeToVisible(NSRange(location: location, length: 0))
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

    private func handleMarker(_ marker: VaulttyMarker, isReplay: Bool, in tab: TerminalTab) {
        switch marker.kind {
        case .commandStarted, .commandFinished:
            let oscPayload = "133;\(marker.rawValue)"
            guard oscPayload.withCString({ vaulttyGhosttyOscCommandType($0) }) == 3 else {
                return
            }
        default:
            break
        }
        switch marker.kind {
        case .shellReady(let cwd):
            tab.commandLifecycle.apply(.shellReady(cwd: cwd))
            updateCommandBarDirectoryStatus(for: tab, forceRefresh: true)
            updateCommandBarVisibility(for: tab)
            updateTabTitleForDirectory(tab)
            persistSessionState()
            runInitialCommandIfNeeded(in: tab)
        case .commandStarted:
            tab.commandLifecycle.apply(.commandStarted)
        case .cwdChanged(let cwd):
            if let cwd {
                tab.commandLifecycle.apply(.cwdChanged(cwd))
            }
            persistSessionState()
        case .openRemoteCode(let payload):
            if !isReplay {
                openRemoteCode(payload: payload, in: tab)
            }
        case .commandFinished(let status):
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
            stopRunningElapsedUpdates(for: tab)
            stopTtyModePolling(for: tab)
            setTerminalControl(false, in: tab)
            updateCommandBarDirectoryStatus(for: tab, forceRefresh: true)
            updateCommandBarVisibility(for: tab)
            updateTabTitleForDirectory(tab)
            persistSessionState()
            scrollToBottom(tab)
            focusInput(for: tab)
            runInitialCommandIfNeeded(in: tab)
        case .unknown:
            break
        }
    }

    private func recordSuccessfulCommand(_ command: String, cwd: String, in tab: TerminalTab) {
        let location = tab.sessionRef.location
        let relayProvider = (tab.session as? RelayTerminalSession)?.completionProvider
        completionQueue.async { [weak self] in
            self?.completionEngine.recordSuccessfulCommand(
                command,
                cwd: cwd,
                location: location,
                relayProvider: relayProvider
            )
        }
    }

    private var remoteCodeFunctionScript: String {
        """
        code() {
          if [ "$#" -eq 0 ]; then
            printf 'usage: code PATH\\n' >&2
            return 2
          fi
          local __vaultty_target="$1" __vaultty_kind __vaultty_dir __vaultty_name __vaultty_abs
          if [ -d "$__vaultty_target" ]; then
            __vaultty_kind=folder
            __vaultty_abs="$(cd "$__vaultty_target" 2>/dev/null && pwd -P)" || return 1
          else
            __vaultty_kind=file
            case "$__vaultty_target" in
              */*) __vaultty_dir="${__vaultty_target%/*}"; __vaultty_name="${__vaultty_target##*/}" ;;
              *) __vaultty_dir=.; __vaultty_name="$__vaultty_target" ;;
            esac
            [ -n "$__vaultty_dir" ] || __vaultty_dir=/
            __vaultty_abs="$(cd "$__vaultty_dir" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$__vaultty_name")" || return 1
          fi
          printf '\\033]133;O;%s;%s\\a' "$__vaultty_kind" "$(printf '%s' "$__vaultty_abs" | base64 | tr -d '\\n')"
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
        if let button = tabButtons[tab.id] {
            button.updateTitle(
                standardTitle,
                hostPrefix: hostname(for: tab.sessionRef),
                detail: detail
            )
            layoutTabStripBeforeMeasuringSelection()
            updateActiveTabCutoutFrame()
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

    private func startTtyModePolling(for tab: TerminalTab) {
        stopTtyModePolling(for: tab)
        tab.ttyModeTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self, weak tab] timer in
            guard let self, let tab else {
                timer.invalidate()
                return
            }
            guard self.isCommandRunning(in: tab) else {
                self.stopTtyModePolling(for: tab)
                return
            }
            self.refreshTerminalControl(in: tab)
        }
    }

    private func stopTtyModePolling(for tab: TerminalTab) {
        tab.ttyModeTimer?.invalidate()
        tab.ttyModeTimer = nil
    }

    private func refreshTerminalControl(in tab: TerminalTab) {
        let isRawInputMode = tab.session.isCanonicalInputModeEnabled() == false
        setTerminalControl(isCommandRunning(in: tab) && (tab.isAlternateScreenActive || isRawInputMode), in: tab)
    }

    private func setTerminalControl(_ isActive: Bool, in tab: TerminalTab) {
        guard tab.isTerminalControlActive != isActive else {
            updateCommandBarVisibility(for: tab)
            return
        }

        tab.isTerminalControlActive = isActive
        updatePassthroughVisibility(for: tab)
        updateCommandBarVisibility(for: tab)

        resizePtyToViewport(for: tab)
        focusInput(for: tab)
        scrollToBottom(tab)
    }

    private func updateCommandBarVisibility(for tab: TerminalTab) {
        let shouldShowCommandBar = tab.isFindMode || (!tab.isTerminalControlActive && !isCommandRunning(in: tab))
        tab.commandBarView.isHidden = !shouldShowCommandBar
        tab.commandSeparator.isHidden = !shouldShowCommandBar
        tab.scrollBottomToCommandBarConstraint?.isActive = shouldShowCommandBar
        tab.scrollBottomToRootConstraint?.isActive = !shouldShowCommandBar
        updateRunningIndicator(for: tab, showsRunningIndicator: !shouldShowCommandBar)
        tab.rootView.needsLayout = true
        tab.rootView.layoutSubtreeIfNeeded()
    }

    private func updateRunningIndicator(for tab: TerminalTab, showsRunningIndicator: Bool? = nil) {
        guard let button = tabButtons[tab.id] else { return }
        updateRunningIndicator(for: tab, button: button, showsRunningIndicator: showsRunningIndicator)
    }

    private func updateRunningIndicator(
        for tab: TerminalTab,
        button: TitleTabButton,
        showsRunningIndicator: Bool? = nil
    ) {
        button.showsRunningIndicator = showsRunningIndicator ?? tab.commandBarView.isHidden
    }

    private func focusInput(for tab: TerminalTab) {
        guard activeTabID == tab.id else { return }
        view.window?.makeFirstResponder(commandFocusTarget(for: tab))
    }

    private func updatePassthroughVisibility(for tab: TerminalTab) {
        tab.ptyPassthroughView.isHidden = !shouldSendInputToPty(in: tab)
    }

    private func shouldSendInputToPty(in tab: TerminalTab) -> Bool {
        !tab.isFindMode && (tab.isTerminalControlActive || isCommandRunning(in: tab))
    }

    private func resizePtyToViewport(for tab: TerminalTab) {
        guard let gridSize = terminalGridSize(for: tab) else { return }
        tab.outputProcessor.resize(rows: Int(gridSize.rows), cols: Int(gridSize.cols))
        tab.session.resize(rows: gridSize.rows, cols: gridSize.cols)
    }

    private func terminalGridSize(for tab: TerminalTab) -> TerminalGridSize? {
        let viewport = tab.scrollView.contentView.bounds
        guard viewport.width > 0, viewport.height > 0 else { return nil }

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let characterWidth = max(1, ceil(("W" as NSString).size(withAttributes: [.font: font]).width))
        let lineHeight = max(1, ceil(font.ascender - font.descender + font.leading))
        let cols = UInt16(max(20, Int(viewport.width / characterWidth)))
        let rows = UInt16(max(5, Int(viewport.height / lineHeight)))
        return TerminalGridSize(rows: rows, cols: cols)
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
        if !tab.stackView.arrangedSubviews.isEmpty {
            let separator = SeparatorView()
            tab.stackView.addArrangedSubview(separator)
            separator.widthAnchor.constraint(equalTo: tab.stackView.widthAnchor).isActive = true
        }

        let blockView = BlockView()
        blockView.update(with: block)
        blockView.onCopyCommand = { [weak self] in
            self?.copy(block.command)
        }
        blockView.onCopyOutput = { [weak self, weak tab] in
            let latest = tab?.blocks.first(where: { $0.id == block.id })
            self?.copy(latest?.output ?? "")
        }
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
        tab.stackView.addArrangedSubview(blockView)
        blockView.translatesAutoresizingMaskIntoConstraints = false
        blockView.widthAnchor.constraint(equalTo: tab.stackView.widthAnchor).isActive = true
        tab.blockViews[block.id] = blockView
        if tab.isFindMode {
            updateFindResults(in: tab, bounce: false)
        }
        scrollToBottom(tab)
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
            tab.inputView.string = initialCommand
            submitCommand(in: tab)
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
        ensureBlockView(for: blockID, in: tab)
        tab.blockViews[blockID]?.update(with: block)
        scrollToBottom(tab)
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
        guard let documentView = tab.scrollView.documentView else {
            return
        }
        documentView.layoutSubtreeIfNeeded()
        tab.scrollView.contentView.layoutSubtreeIfNeeded()
        let maxY = max(0, documentView.bounds.height - tab.scrollView.contentView.bounds.height)
        tab.scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxY))
        tab.scrollView.reflectScrolledClipView(tab.scrollView.contentView)
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

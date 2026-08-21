import AppKit
import Foundation
import QuartzCore

enum PortalLauncherAppearance {
    static let effectOutset: CGFloat = 14
}

@MainActor
private final class PortalTendrilView: NSView {
    private let aura = CAGradientLayer()
    private let wisps = CAGradientLayer()
    private let strands = CAGradientLayer()
    private let sparks = CAGradientLayer()
    private let auraMask = CALayer()
    private let wispMask = CALayer()
    private let strandMask = CALayer()
    private let sparkMask = CALayer()
    private var wispLayers: [CAShapeLayer] = []
    private var sparkLayers: [CAShapeLayer] = []
    private var renderedSize = CGSize.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        [aura, wisps, strands, sparks].forEach(configureGradient)
        aura.mask = auraMask
        wisps.mask = wispMask
        strands.mask = strandMask
        sparks.mask = sparkMask
        aura.opacity = 0.5
        wisps.opacity = 0.75
        strands.opacity = 0.9
        layer?.addSublayer(aura)
        layer?.addSublayer(wisps)
        layer?.addSublayer(strands)
        layer?.addSublayer(sparks)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0, bounds.size != renderedSize else { return }
        renderedSize = bounds.size

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for gradient in [aura, wisps, strands, sparks] {
            gradient.frame = bounds
            gradient.mask?.frame = bounds
        }
        rebuildTendrils()
        CATransaction.commit()
        updateAnimations()
    }

    static func pathSelfTest() -> Bool {
        let bounds = CGRect(x: 0, y: 0, width: 720, height: 420)
        let box = tendrilPath(in: bounds, strand: 2).boundingBoxOfPath
        let wispBoxes = [-0.85, 0, 1.15].map { wispPath(in: bounds, index: 3, wave: $0).boundingBoxOfPath }
        return box.width > 690 && box.height > 390 && bounds.contains(box)
            && wispBoxes.allSatisfy { !$0.isEmpty && bounds.contains($0) && box.intersects($0) }
    }

    private func configureGradient(_ gradient: CAGradientLayer) {
        gradient.colors = [
            NSColor(red: 0.16, green: 0.72, blue: 1, alpha: 1).cgColor,
            NSColor(red: 0.52, green: 0.56, blue: 1, alpha: 1).cgColor,
            NSColor(red: 0.82, green: 0.25, blue: 1, alpha: 1).cgColor,
        ]
        gradient.locations = [0, 0.5, 1]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
    }

    private func rebuildTendrils() {
        [auraMask, wispMask, strandMask, sparkMask].forEach { mask in
            mask.sublayers?.forEach { $0.removeFromSuperlayer() }
        }
        wispLayers.removeAll()
        sparkLayers.removeAll()

        for index in 0..<3 {
            let strand = index + 1
            auraMask.addSublayer(shapeLayer(
                path: Self.tendrilPath(in: bounds, strand: strand),
                lineWidth: CGFloat(12 - index * 3),
                opacity: Float(0.055 + Double(index) * 0.025)
            ))
        }
        for strand in 0..<11 {
            strandMask.addSublayer(shapeLayer(
                path: Self.tendrilPath(in: bounds, strand: strand),
                lineWidth: 0.55 + CGFloat(strand % 4) * 0.28,
                opacity: 0.24 + Float(strand % 5) * 0.1
            ))
        }
        for index in 0..<8 {
            let wisp = shapeLayer(
                path: Self.wispPath(in: bounds, index: index),
                lineWidth: 0.7 + CGFloat(index % 3) * 0.25,
                opacity: 0.42 + Float(index % 4) * 0.09
            )
            wispMask.addSublayer(wisp)
            wispLayers.append(wisp)
        }
        for strand in 0..<6 {
            let spark = shapeLayer(
                path: Self.tendrilPath(in: bounds, strand: strand + 2),
                lineWidth: 1.2 + CGFloat(strand % 3) * 0.45,
                opacity: 0.95
            )
            spark.lineDashPattern = [NSNumber(value: 2 + strand % 2), 34, 1, 72]
            sparkMask.addSublayer(spark)
            sparkLayers.append(spark)
        }
    }

    private func shapeLayer(path: CGPath, lineWidth: CGFloat, opacity: Float) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.frame = bounds
        shape.path = path
        shape.fillColor = nil
        shape.strokeColor = NSColor.white.withAlphaComponent(CGFloat(opacity)).cgColor
        shape.lineWidth = lineWidth
        shape.lineCap = .round
        shape.lineJoin = .round
        return shape
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        updateAnimations()
    }

    private func updateAnimations() {
        [aura, wisps, strands, sparks].forEach { $0.removeAllAnimations() }
        wispLayers.forEach { $0.removeAllAnimations() }
        sparkLayers.forEach { $0.removeAllAnimations() }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.28
        breathe.toValue = 0.64
        breathe.duration = 3.8
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        aura.add(breathe, forKey: "portal-breathe")

        let shimmer = CABasicAnimation(keyPath: "opacity")
        shimmer.fromValue = 0.68
        shimmer.toValue = 1
        shimmer.duration = 2.4
        shimmer.autoreverses = true
        shimmer.repeatCount = .infinity
        strands.add(shimmer, forKey: "portal-shimmer")

        for (index, wisp) in wispLayers.enumerated() {
            let start = CAKeyframeAnimation(keyPath: "strokeStart")
            start.values = [0, 0, 0.38, 0.76, 1]
            start.keyTimes = [0, 0.18, 0.52, 0.8, 1]

            let end = CAKeyframeAnimation(keyPath: "strokeEnd")
            end.values = [0.12, 0.52, 0.86, 1, 1]
            end.keyTimes = start.keyTimes

            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.9, 0.72, 0.28, 0]
            fade.keyTimes = start.keyTimes

            let drift = CAAnimationGroup()
            drift.animations = [start, end, fade]
            drift.duration = 4.8 + Double(index % 4) * 0.65
            drift.timeOffset = Double(index) * 0.57
            drift.repeatCount = .infinity
            wisp.add(drift, forKey: "portal-wisp")

            let wave = CAKeyframeAnimation(keyPath: "path")
            wave.values = [0, 1.15, -0.85, 0].map {
                Self.wispPath(in: bounds, index: index, wave: CGFloat($0))
            }
            wave.keyTimes = [0, 0.32, 0.68, 1]
            wave.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
            wave.duration = 12.4 + Double(index % 4) * 1.75
            wave.timeOffset = Double(index) * 1.37
            wave.repeatCount = .infinity
            wisp.add(wave, forKey: "portal-wave")
        }

        let pacing: [[Double]] = [
            [0, 0.08, 0.46, 0.62, 1],
            [0, 0.24, 0.39, 0.79, 1],
            [0, 0.13, 0.55, 0.73, 1],
        ]
        let keyTimes = [0.0, 0.2, 0.45, 0.72, 1.0].map { NSNumber(value: $0) }
        let phaseCycles = 3.0
        for (index, spark) in sparkLayers.enumerated() {
            let cycle = spark.lineDashPattern?.reduce(CGFloat.zero) { $0 + CGFloat(truncating: $1) } ?? 109
            let direction: CGFloat = index.isMultiple(of: 2) ? -1 : 1
            let travel = CAKeyframeAnimation(keyPath: "lineDashPhase")
            travel.values = pacing[index % pacing.count].map {
                NSNumber(value: Double(direction * cycle) * phaseCycles * $0)
            }
            travel.keyTimes = keyTimes
            travel.timingFunctions = [
                CAMediaTimingFunction(name: .easeIn),
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeOut),
            ]
            travel.duration = 10.8 + Double(index) * 1.35
            travel.timeOffset = Double(index) * 1.73
            travel.repeatCount = .infinity
            spark.add(travel, forKey: "portal-travel")
        }
    }

    private static func tendrilPath(in bounds: CGRect, strand: Int) -> CGPath {
        let path = CGMutablePath()
        let inset = PortalLauncherAppearance.effectOutset - 4 + CGFloat(strand % 5) * 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let radius = min(14, rect.height / 2)
        let phase = CGFloat(strand) * 1.731
        let samples = max(96, Int((rect.width + rect.height) / 5))

        for sample in 0...samples {
            let t = CGFloat(sample) / CGFloat(samples)
            let position = point(on: rect, radius: radius, fraction: t)
            let neighbor = point(
                on: rect,
                radius: radius,
                fraction: sample == samples ? t - 0.001 : t + 0.001
            )
            let tangent = sample == samples
                ? CGPoint(x: position.x - neighbor.x, y: position.y - neighbor.y)
                : CGPoint(x: neighbor.x - position.x, y: neighbor.y - position.y)
            let length = max(0.001, hypot(tangent.x, tangent.y))
            let normal = CGPoint(x: -tangent.y / length, y: tangent.x / length)
            let wave = sin(t * .pi * CGFloat(10 + strand % 4) + phase) * (0.8 + CGFloat(strand % 3) * 0.32)
                + sin(t * .pi * CGFloat(27 + strand % 5) - phase * 0.7) * 0.45
            let p = CGPoint(x: position.x + normal.x * wave, y: position.y + normal.y * wave)
            sample == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        path.closeSubpath()
        return path
    }

    private static func wispPath(in bounds: CGRect, index: Int, wave: CGFloat = 0) -> CGPath {
        let path = CGMutablePath()
        let rect = bounds.insetBy(dx: PortalLauncherAppearance.effectOutset, dy: PortalLauncherAppearance.effectOutset)
        let starts: [CGFloat] = [0.025, 0.14, 0.25, 0.36, 0.485, 0.6, 0.72, 0.84]
        let start = starts[index % starts.count]
        let span = 0.065 + CGFloat(index % 3) * 0.012

        for sample in 0...28 {
            let progress = CGFloat(sample) / 28
            let fraction = start + span * progress
            let position = point(on: rect, radius: 14, fraction: fraction)
            let neighbor = point(on: rect, radius: 14, fraction: fraction + 0.001)
            let tangent = CGPoint(x: neighbor.x - position.x, y: neighbor.y - position.y)
            let length = max(0.001, hypot(tangent.x, tangent.y))
            let normal = CGPoint(x: -tangent.y / length, y: tangent.x / length)
            let envelope = sin(.pi * progress)
            let lift = 1.2 + envelope * (2.4 + CGFloat(index % 4) * 1.05)
            let flutter = (
                sin(progress * .pi * CGFloat(3 + index % 3) + CGFloat(index) + wave) * 0.75
                    + sin(wave * 0.9) * 0.55
            ) * envelope
            let p = CGPoint(
                x: position.x + normal.x * (lift + flutter),
                y: position.y + normal.y * (lift + flutter)
            )
            sample == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        return path
    }

    private static func point(on rect: CGRect, radius: CGFloat, fraction: CGFloat) -> CGPoint {
        let horizontal = rect.width - radius * 2
        let vertical = rect.height - radius * 2
        let arc = radius * .pi / 2
        var distance = min(max(fraction, 0), 1) * (horizontal * 2 + vertical * 2 + arc * 4)

        if distance <= horizontal { return CGPoint(x: rect.minX + radius + distance, y: rect.maxY) }
        distance -= horizontal
        if distance <= arc {
            let angle = .pi / 2 - distance / radius
            return CGPoint(x: rect.maxX - radius + cos(angle) * radius, y: rect.maxY - radius + sin(angle) * radius)
        }
        distance -= arc
        if distance <= vertical { return CGPoint(x: rect.maxX, y: rect.maxY - radius - distance) }
        distance -= vertical
        if distance <= arc {
            let angle = -distance / radius
            return CGPoint(x: rect.maxX - radius + cos(angle) * radius, y: rect.minY + radius + sin(angle) * radius)
        }
        distance -= arc
        if distance <= horizontal { return CGPoint(x: rect.maxX - radius - distance, y: rect.minY) }
        distance -= horizontal
        if distance <= arc {
            let angle = -.pi / 2 - distance / radius
            return CGPoint(x: rect.minX + radius + cos(angle) * radius, y: rect.minY + radius + sin(angle) * radius)
        }
        distance -= arc
        if distance <= vertical { return CGPoint(x: rect.minX, y: rect.minY + radius + distance) }
        distance -= vertical
        let angle = .pi - distance / radius
        return CGPoint(x: rect.minX + radius + cos(angle) * radius, y: rect.maxY - radius + sin(angle) * radius)
    }
}

private final class LauncherSessionDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class LauncherViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private static let sessionColumnCount = 3

    private enum Row {
        case session(SessionPickerItem)
        case completion(CompletionSuggestion)
        case message(String)

        var isSelectable: Bool {
            switch self {
            case .session, .completion: true
            case .message: false
            }
        }
    }

    var onRunCommand: ((String) -> Void)?
    var onOpenSession: ((SessionPickerCandidate) -> Void)?
    var onLaunchApplication: ((CompletionSuggestion) -> Void)?
    var onCancel: (() -> Void)?
    var onHeightChanged: ((CGFloat) -> Void)?

    private let input = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let sessionScroll = NSScrollView()
    private let sessionDocument = LauncherSessionDocument()
    private let sessionStack = NSStackView()
    private let completionEngine = PortalCompletionEngine()
    private let completionQueue = DispatchQueue(label: "dev.mxcl.portal.launcher-completion", qos: .userInitiated)
    private let sessionModel = SessionPickerModel()
    private var rows: [Row] = []
    private var sessionButtons: [SessionCandidateButton] = []
    private var sessionRowStarts: [Int] = []
    private var sessionCandidates: [SessionRef: SessionPickerCandidate] = [:]
    private var renderedSnapshot: SessionPickerSnapshot?
    private var selectedSessionRef: SessionRef?
    private var sessionMouseDownMonitor: Any?
    private var completionSerial = 0

    static func keyboardSelectionSelfTest() -> Bool {
        let rows = [0, 3, 5, 8, 11]
        return PortalTendrilView.pathSelfTest()
            && sessionSelectionDestination(current: nil, delta: -3, rowStarts: rows, count: 13) == 11
            && sessionSelectionDestination(current: 7, delta: -1, rowStarts: rows, count: 13) == 6
            && sessionSelectionDestination(current: 5, delta: -1, rowStarts: rows, count: 13) == nil
            && sessionSelectionDestination(current: 5, delta: 1, rowStarts: rows, count: 13) == 6
            && sessionSelectionDestination(current: 7, delta: 1, rowStarts: rows, count: 13) == nil
            && sessionSelectionDestination(current: 9, delta: -3, rowStarts: rows, count: 13) == 6
            && sessionSelectionDestination(current: 7, delta: -3, rowStarts: rows, count: 13) == 4
            && sessionSelectionDestination(current: 4, delta: 3, rowStarts: rows, count: 13) == 6
            && sessionSelectionDestination(current: 6, delta: 3, rowStarts: rows, count: 13) == 9
    }

    override func loadView() {
        let container = NSView()
        let glass = NSGlassEffectView()
        glass.cornerRadius = 18
        glass.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        glass.contentView = content
        container.addSubview(glass)
        view = container

        input.delegate = self
        input.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        input.placeholderString = "Run a command or open an app"
        input.focusRingType = .none
        input.isBordered = false
        input.drawsBackground = false
        input.setAccessibilityLabel("Portal command launcher")
        input.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("result"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(openSelectedRow(_:))

        sessionDocument.translatesAutoresizingMaskIntoConstraints = false
        sessionStack.orientation = .vertical
        sessionStack.alignment = .leading
        sessionStack.spacing = 10
        sessionStack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 0, right: 16)
        sessionStack.translatesAutoresizingMaskIntoConstraints = false
        sessionDocument.addSubview(sessionStack)
        NSLayoutConstraint.activate([
            sessionStack.leadingAnchor.constraint(equalTo: sessionDocument.leadingAnchor),
            sessionStack.trailingAnchor.constraint(equalTo: sessionDocument.trailingAnchor),
            sessionStack.topAnchor.constraint(equalTo: sessionDocument.topAnchor),
            sessionStack.bottomAnchor.constraint(equalTo: sessionDocument.bottomAnchor),
        ])

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.isHidden = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        sessionScroll.documentView = sessionDocument
        sessionScroll.drawsBackground = false
        sessionScroll.hasVerticalScroller = true
        sessionScroll.autohidesScrollers = true
        sessionScroll.automaticallyAdjustsContentInsets = false
        sessionScroll.verticalScrollElasticity = .none
        sessionScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sessionDocument.topAnchor.constraint(equalTo: sessionScroll.contentView.topAnchor),
            sessionDocument.widthAnchor.constraint(equalTo: sessionScroll.contentView.widthAnchor),
        ])

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(input)
        content.addSubview(separator)
        content.addSubview(scroll)
        content.addSubview(sessionScroll)
        let tendrils = PortalTendrilView()
        tendrils.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tendrils)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: PortalLauncherAppearance.effectOutset),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -PortalLauncherAppearance.effectOutset),
            glass.topAnchor.constraint(equalTo: container.topAnchor, constant: PortalLauncherAppearance.effectOutset),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -PortalLauncherAppearance.effectOutset),
            input.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            input.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            input.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -56),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor),
            sessionScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sessionScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            sessionScroll.topAnchor.constraint(equalTo: content.topAnchor),
            sessionScroll.bottomAnchor.constraint(equalTo: separator.topAnchor),
            tendrils.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tendrils.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tendrils.topAnchor.constraint(equalTo: container.topAnchor),
            tendrils.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        sessionMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self,
                  event.window === self.view.window,
                  !self.sessionScroll.isHidden,
                  let button = self.sessionButtons.first(where: {
                      $0.bounds.contains($0.convert(event.locationInWindow, from: nil))
                  })
            else { return event }
            self.openSessionCard(button)
            return nil
        }
        refreshSessions()
    }

    deinit {
        if let sessionMouseDownMonitor {
            NSEvent.removeMonitor(sessionMouseDownMonitor)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(input)
    }

    func reset() {
        completionSerial += 1
        selectedSessionRef = nil
        sessionButtons.forEach { $0.isKeyboardSelected = false }
        input.stringValue = ""
        refreshSessions()
        view.window?.makeFirstResponder(input)
    }

    func suspend() {
        completionSerial += 1
        sessionModel.invalidate()
    }

    func showError(_ message: String) {
        scroll.isHidden = false
        sessionScroll.isHidden = true
        rows = [.message(message)]
        reloadRows()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 52
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows.indices.contains(row) && rows[row].isSelectable
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .session(let item):
            return resultCell(
                title: item.subtitle ?? item.title,
                detail: item.subtitle == nil ? item.metadata : "\(item.title) · \(item.metadata)",
                icon: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
            )
        case .message(let message):
            let label = NSTextField(labelWithString: message)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            return label
        case .completion(let suggestion):
            let icon = suggestion.kind == .application
                ? NSWorkspace.shared.icon(forFile: suggestion.source)
                : NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
            return resultCell(
                title: suggestion.displayText,
                detail: suggestion.description ?? suggestion.source,
                icon: icon
            )
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        let query = input.stringValue
        if query.isEmpty {
            refreshSessions()
        } else {
            refreshCompletions(query)
        }
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            input.stringValue.isEmpty ? moveSessionSelection(columns: Self.sessionColumnCount) : moveSelection(1)
        case #selector(NSResponder.moveUp(_:)):
            input.stringValue.isEmpty ? moveSessionSelection(columns: -Self.sessionColumnCount) : moveSelection(-1)
        case #selector(NSResponder.moveLeft(_:)) where input.stringValue.isEmpty:
            moveSessionSelection(columns: -1)
        case #selector(NSResponder.moveRight(_:)) where input.stringValue.isEmpty:
            moveSessionSelection(columns: 1)
        case #selector(NSResponder.insertTab(_:)):
            acceptSelectedCompletion()
        case #selector(NSResponder.insertNewline(_:)):
            activateSelectionOrInput()
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
        default:
            return false
        }
        return true
    }

    @objc private func openSelectedRow(_ sender: Any?) {
        activateSelectionOrInput()
    }

    private func resultCell(title: String, detail: String, icon: NSImage?) -> NSTableCellView {
        let cell = NSTableCellView()
        let image = NSImageView()
        image.image = icon
        image.imageScaling = .scaleProportionallyDown
        image.translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(labels)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 28),
            image.heightAnchor.constraint(equalToConstant: 28),
            labels.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func refreshSessions() {
        scroll.isHidden = true
        sessionScroll.isHidden = false
        let hostname = Host.current().localizedName ?? "This Mac"
        sessionModel.refresh(
            initial: renderedSnapshot?.sections.flatMap { $0.items.map(\.candidate) } ?? [],
            excluding: [],
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            loadLocal: {
                try? PtySession.listSessions().map { session in
                    SessionPickerCandidate(
                        sessionRef: .local(session.sessionID),
                        hostTitle: hostname,
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
            },
            loadRelay: { await Self.relayCandidates() },
            isAvailable: { _ in true },
            onUpdate: { [weak self] snapshot in
                guard let self, snapshot != self.renderedSnapshot else { return }
                self.renderedSnapshot = snapshot
                guard self.input.stringValue.isEmpty else { return }
                self.renderSessions(snapshot)
            }
        )
    }

    private func renderSessions(_ snapshot: SessionPickerSnapshot) {
        sessionCandidates = Dictionary(uniqueKeysWithValues: snapshot.sections.flatMap { section in
            section.items.map { ($0.candidate.sessionRef, $0.candidate) }
        })
        sessionButtons.removeAll()
        sessionRowStarts.removeAll()
        for view in sessionStack.arrangedSubviews {
            sessionStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for section in snapshot.sections {
            let header = NSTextField(labelWithString: section.title.uppercased())
            header.font = .systemFont(ofSize: 10, weight: .semibold)
            header.textColor = .secondaryLabelColor
            sessionStack.addArrangedSubview(header)

            if section.items.isEmpty {
                let empty = NSTextField(labelWithString: "No active sessions")
                empty.font = .systemFont(ofSize: 12, weight: .regular)
                empty.textColor = .tertiaryLabelColor
                empty.alignment = .center
                empty.heightAnchor.constraint(equalToConstant: 82).isActive = true
                sessionStack.addArrangedSubview(empty)
                empty.widthAnchor.constraint(equalTo: sessionStack.widthAnchor).isActive = true
                continue
            }

            for start in stride(from: 0, to: section.items.count, by: Self.sessionColumnCount) {
                sessionRowStarts.append(sessionButtons.count)
                let buttons = section.items[start..<min(start + Self.sessionColumnCount, section.items.count)].map { item in
                    let button = SessionCandidateButton(
                        sessionRef: item.candidate.sessionRef,
                        title: item.title,
                        subtitle: item.subtitle,
                        metadata: item.metadata
                    )
                    button.target = self
                    button.action = #selector(openSessionCard(_:))
                    button.isKeyboardSelected = item.candidate.sessionRef == selectedSessionRef
                    sessionButtons.append(button)
                    return button
                }
                let row = SessionCandidateRowView(buttons: buttons, columnCount: Self.sessionColumnCount)
                sessionStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: sessionStack.widthAnchor).isActive = true
            }
        }

        if let selectedSessionRef, !sessionCandidates.keys.contains(selectedSessionRef) {
            self.selectedSessionRef = nil
        }
        sessionDocument.layoutSubtreeIfNeeded()
        onHeightChanged?(57 + sessionStack.fittingSize.height)
    }

    @objc private func openSessionCard(_ sender: SessionCandidateButton) {
        guard let candidate = sessionCandidates[sender.sessionRef] else { return }
        selectedSessionRef = sender.sessionRef
        onOpenSession?(candidate)
    }

    private func refreshCompletions(_ query: String) {
        scroll.isHidden = false
        sessionScroll.isHidden = true
        rows = matchingSessionRows(query)
        reloadRows(selectsFirst: !rows.isEmpty)
        completionSerial += 1
        let serial = completionSerial
        let cancellation = CompletionCancellation()
        let request = CompletionRequest(
            input: query,
            cursorOffset: query.utf16.count,
            cwd: FileManager.default.homeDirectoryForCurrentUser.path,
            shellPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
            environment: ProcessInfo.processInfo.environment,
            location: .local,
            limit: 64,
            cancellation: cancellation,
            relayProvider: nil,
            includesHistory: query.utf16.count >= 2,
            historyOnly: false
        )
        completionQueue.async { [weak self] in
            guard let self else { return }
            let result = self.completionEngine.completions(for: request)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      serial == self.completionSerial,
                      self.input.stringValue == query
                else { return }
                self.rows = self.matchingSessionRows(query) + result.suggestions.map(Row.completion)
                if self.rows.isEmpty {
                    self.rows = [.message("Return to run “\(query)”")]
                }
                self.reloadRows(selectsFirst: true)
            }
        }
    }

    private func matchingSessionRows(_ query: String) -> [Row] {
        renderedSnapshot?.matchingItems(query).map(Row.session) ?? []
    }

    private func reloadRows(selectsFirst: Bool = false) {
        table.reloadData()
        if selectsFirst, let row = rows.firstIndex(where: \.isSelectable) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let rowsHeight = rows.prefix(8).enumerated().reduce(CGFloat.zero) { height, pair in
            height + tableView(table, heightOfRow: pair.offset)
        }
        onHeightChanged?(min(57 + rowsHeight, 57 + 8 * 52))
    }

    private func moveSelection(_ offset: Int) {
        let selectable = rows.indices.filter { rows[$0].isSelectable }
        guard !selectable.isEmpty else { return }
        let current = table.selectedRow
        let index = selectable.firstIndex(of: current) ?? (offset > 0 ? -1 : 0)
        let next = (index + offset + selectable.count) % selectable.count
        table.selectRowIndexes(IndexSet(integer: selectable[next]), byExtendingSelection: false)
        table.scrollRowToVisible(selectable[next])
    }

    private func moveSessionSelection(columns delta: Int) {
        guard !sessionButtons.isEmpty else { return }
        let current = selectedSessionRef.flatMap { selected in
            sessionButtons.firstIndex { $0.sessionRef == selected }
        }
        guard let destination = Self.sessionSelectionDestination(
            current: current,
            delta: delta,
            rowStarts: sessionRowStarts,
            count: sessionButtons.count
        ) else { return }
        sessionButtons.forEach { $0.isKeyboardSelected = false }
        let button = sessionButtons[destination]
        button.isKeyboardSelected = true
        selectedSessionRef = button.sessionRef
        button.scrollToVisible(button.bounds)
    }

    private static func sessionSelectionDestination(
        current: Int?,
        delta: Int,
        rowStarts: [Int],
        count: Int
    ) -> Int? {
        guard count > 0, !rowStarts.isEmpty else { return nil }
        guard let current else {
            return delta == -1 ? count - 1 : delta < 0 ? rowStarts.last : 0
        }
        guard let row = rowStarts.lastIndex(where: { $0 <= current }) else { return nil }
        let rowEnd = (rowStarts.indices.contains(row + 1) ? rowStarts[row + 1] : count) - 1
        if delta == -1 { return current > rowStarts[row] ? current - 1 : nil }
        if delta == 1 { return current < rowEnd ? current + 1 : nil }

        let targetRow = row + (delta < 0 ? -1 : 1)
        guard rowStarts.indices.contains(targetRow) else { return nil }
        let targetEnd = (rowStarts.indices.contains(targetRow + 1) ? rowStarts[targetRow + 1] : count) - 1
        return min(rowStarts[targetRow] + current - rowStarts[row], targetEnd)
    }

    private func acceptSelectedCompletion() {
        guard rows.indices.contains(table.selectedRow),
              case .completion(let suggestion) = rows[table.selectedRow]
        else { return }
        input.stringValue = suggestion.insertText
        refreshCompletions(input.stringValue)
    }

    private func activateSelectionOrInput() {
        if input.stringValue.isEmpty,
           let selectedSessionRef,
           let candidate = sessionCandidates[selectedSessionRef] {
            onOpenSession?(candidate)
            return
        }
        if !input.stringValue.isEmpty, rows.indices.contains(table.selectedRow) {
            switch rows[table.selectedRow] {
            case .session(let item):
                onOpenSession?(item.candidate)
                return
            case .completion(let suggestion):
                if suggestion.kind == .application {
                    input.stringValue = suggestion.insertText
                    onLaunchApplication?(suggestion)
                } else {
                    onRunCommand?(suggestion.insertText.trimmingCharacters(in: .whitespaces))
                }
                return
            case .message:
                break
            }
        }
        let command = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !command.isEmpty { onRunCommand?(command) }
    }

    private static func relayCandidates() async -> [SessionPickerCandidate]? {
        guard let endpoint = try? MacRemoteAccessController.relayEndpoint(),
              let key = try? ICloudKeychainRootKey().loadOrCreate(),
              let client = try? RelayCatalogClient(endpoint: endpoint, rootKeyData: key),
              let data = try? await client.load(),
              let catalog = try? JSONDecoder().decode(RemoteCatalog.self, from: data)
        else { return nil }

        let now = Date()
        let localMacID = MacRemoteAccessController.macID()
        return catalog.macs
            .filter { $0.id != localMacID && $0.online && now.timeIntervalSince($0.lastSeen) < 10 }
            .flatMap { mac in
                mac.sessions.map { session in
                    SessionPickerCandidate(
                        sessionRef: SessionRef(
                            location: .relayMac(mac.id),
                            sessionID: session.sessionID,
                            hostName: mac.name
                        ),
                        hostTitle: mac.name,
                        title: session.title,
                        cwd: session.cwd,
                        isClosed: false,
                        createdAt: session.createdAt,
                        commandCount: session.commandCount,
                        lastCommandAt: session.lastCommandAt,
                        runningCommand: session.runningCommand,
                        commandHistory: [],
                        action: .attach,
                        attachedClientCount: session.attachedClientCount
                    )
                }
            }
    }
}

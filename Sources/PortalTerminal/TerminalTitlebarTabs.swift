#if os(macOS)
import AppKit

/// A horizontally scrolling strip: each tab keeps its natural title width.
final class TerminalTitlebarTabs: NSTitlebarAccessoryViewController {
    weak var owner: StandaloneTerminalWindow?
    private let scroll = NSScrollView()
    private let stack = NSStackView()

    override func loadView() {
        layoutAttribute = .left
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        scroll.documentView = stack
        view = scroll
    }

    func update(_ windows: [StandaloneTerminalWindow]) {
        loadViewIfNeeded()
        guard let owner else { return }
        for child in stack.arrangedSubviews {
            stack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        for window in windows {
            let tab = TerminalTitlebarTab(title: window.title, selected: window === owner)
            tab.select = { [weak owner, weak window] in
                guard let owner, let window else { return }
                owner.workspace?.select(window, replacing: owner)
            }
            tab.close = { [weak window] in window?.performClose(nil) }
            tab.toolTip = window.tab.toolTip ?? window.title
            stack.addArrangedSubview(tab)
        }
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")!,
                           target: self, action: #selector(newTab))
        add.bezelStyle = .inline
        add.isBordered = false
        add.setAccessibilityLabel("New tab")
        stack.addArrangedSubview(add)
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        view.setFrameSize(NSSize(width: min(stack.frame.width, max(100, owner.frame.width - 110)), height: 32))
        if let selected = stack.arrangedSubviews.first(where: { ($0 as? TerminalTitlebarTab)?.selected == true }) {
            selected.scrollToVisible(selected.bounds)
        }
    }

    @objc private func newTab() {
        guard let owner else { return }
        owner.workspace?.newTab(in: owner)
    }
}

private final class TerminalTitlebarTab: NSView {
    let selected: Bool
    var select: (() -> Void)?
    var close: (() -> Void)?

    init(title: String, selected: Bool) {
        self.selected = selected
        super.init(frame: .zero)
        let label = NSButton(title: title, target: self, action: #selector(selectTab))
        label.isBordered = false
        label.font = .systemFont(ofSize: 12, weight: selected ? .semibold : .regular)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setAccessibilityValue(selected ? "Selected" : "Not selected")
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")!,
                             target: self, action: #selector(closeTab))
        close.isBordered = false
        close.controlSize = .mini
        close.setAccessibilityLabel("Close \(title)")
        let content = NSStackView(views: [label, close])
        content.spacing = 6
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
            close.widthAnchor.constraint(equalToConstant: 14)
        ])
        wantsLayer = true
        layer?.cornerRadius = 9
        updateLayer()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() {
        layer?.backgroundColor = (selected ? NSColor.quaternaryLabelColor : .clear).cgColor
    }

    @objc private func selectTab() { select?() }
    @objc private func closeTab() { close?() }
}
#endif

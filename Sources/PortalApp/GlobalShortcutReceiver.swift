#if os(macOS)
import AppKit
import SwiftUI
import PortalEngine

/// Receives shortcut requests only while the project window exists.
struct GlobalShortcutReceiver: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> ReceiverView { ReceiverView(model: model) }
    func updateNSView(_ view: ReceiverView, context: Context) {}

    final class ReceiverView: NSView {
        private let model: AppModel

        init(model: AppModel) {
            self.model = model
            super.init(frame: .zero)
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(showPalette),
                name: EngineControlProtocol.showPaletteNotification, object: nil
            )
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        deinit { DistributedNotificationCenter.default().removeObserver(self) }

        @objc private func showPalette() {
            guard let window, window.isVisible || window.isMiniaturized else { return }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            model.showPalette(in: window)
        }
    }
}
#endif

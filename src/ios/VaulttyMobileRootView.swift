#if os(iOS)
import SwiftUI
import SwiftTerm
import UIKit
import VaulttyCore

public struct VaulttyMobileRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = MobileRemoteModel()
    @State private var store = MobileStore()
    @State private var createdDestination: CreatedSessionDestination?
    @State private var catalogRefreshRequest = 0

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                if let catalog = model.catalog {
                    ForEach(catalog.macs.sortedAlphabetically) { mac in
                        MobileHostSection(
                            model: model,
                            store: store,
                            mac: mac,
                            isReachable: isMacReachable(mac, catalog: catalog),
                            onCreate: { startNewSession(on: mac) }
                        )
                    }
                }
            }
            .refreshable { await model.refreshCatalog() }
            .background(NativeRefreshControlTrigger(request: catalogRefreshRequest))
            .overlay {
                if !model.isRefreshingCatalog,
                   model.catalog?.macs.isEmpty != false {
                    ContentUnavailableView(
                        "No sessions yet",
                        systemImage: "terminal",
                        description: Text("Enable Remote Access on a Mac with an open InfiniTerm session.")
                    )
                    .allowsHitTesting(false)
                }
            }
            .navigationTitle("InfiniTerm")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        requestCatalogRefresh()
                    }
                    .disabled(model.isRefreshingCatalog)
                }
            }
            .navigationDestination(item: $createdDestination) { destination in
                MobileSessionView(
                    model: model,
                    session: destination.session,
                    mac: destination.mac
                )
                .onAppear {
                    model.attach(
                        to: destination.session,
                        on: destination.mac,
                        store: store
                    )
                }
            }
        }
        .task {
            requestCatalogRefresh()
            await store.load()
        }
        .sheet(isPresented: $model.showsPaywall) {
            MobilePaywall(store: store)
        }
        .alert("Couldn’t Start Session", isPresented: Binding(
            get: { model.sessionCreationError != nil },
            set: { if !$0 { model.dismissSessionCreationError() } }
        )) {
            Button("OK") { model.dismissSessionCreationError() }
        } message: {
            Text(model.sessionCreationError ?? "The Mac could not start a session.")
        }
        .fullScreenCover(isPresented: Binding(
            get: { model.isLocked },
            set: { _ in }
        )) {
            LockedView { model.unlock() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                model.sceneDidEnterBackground()
            case .active:
                model.sceneDidBecomeActive()
                requestCatalogRefresh()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    private func requestCatalogRefresh() {
        guard !model.isRefreshingCatalog else { return }
        catalogRefreshRequest &+= 1
    }

    private func isMacReachable(_ mac: RemoteMac, catalog: RemoteCatalog) -> Bool {
        mac.online && Date().timeIntervalSince(mac.lastSeen) < 10
    }

    private func startNewSession(on mac: RemoteMac) {
        Task {
            guard let session = await model.createSession(on: mac, store: store) else {
                return
            }
            createdDestination = CreatedSessionDestination(mac: mac, session: session)
        }
    }
}

private struct NativeRefreshControlTrigger: UIViewRepresentable {
    let request: Int

    func makeUIView(context: Context) -> TriggerView {
        TriggerView()
    }

    func updateUIView(_ view: TriggerView, context: Context) {
        view.request = request
    }

    final class TriggerView: UIView {
        var request = 0 {
            didSet { triggerIfNeeded() }
        }

        private var handledRequest = 0

        override func didMoveToWindow() {
            super.didMoveToWindow()
            triggerIfNeeded()
        }

        private func triggerIfNeeded() {
            guard request != 0, request != handledRequest,
                  let scrollView = enclosingRefreshableScrollView(),
                  let refreshControl = scrollView.refreshControl else { return }
            handledRequest = request
            guard !refreshControl.isRefreshing else { return }
            refreshControl.beginRefreshing()
            scrollView.setContentOffset(
                CGPoint(
                    x: scrollView.contentOffset.x,
                    y: -scrollView.adjustedContentInset.top - refreshControl.bounds.height
                ),
                animated: true
            )
            refreshControl.sendActions(for: .valueChanged)
        }

        private func enclosingRefreshableScrollView() -> UIScrollView? {
            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view.refreshableScrollView() { return scrollView }
                ancestor = view.superview
            }
            return nil
        }
    }
}

private extension UIView {
    func refreshableScrollView() -> UIScrollView? {
        if let scrollView = self as? UIScrollView, scrollView.refreshControl != nil {
            return scrollView
        }
        for view in subviews {
            if let scrollView = view.refreshableScrollView() { return scrollView }
        }
        return nil
    }
}

private extension Array where Element == RemoteMac {
    var sortedAlphabetically: [RemoteMac] {
        sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }
}

private struct MobileHostSection: View {
    let model: MobileRemoteModel
    let store: MobileStore
    let mac: RemoteMac
    let isReachable: Bool
    let onCreate: () -> Void

    var body: some View {
        Section {
            ForEach(mac.sessions) { session in
                NavigationLink {
                    MobileSessionView(model: model, session: session, mac: mac)
                        .onAppear { model.attach(to: session, on: mac, store: store) }
                } label: {
                    SessionRow(session: session)
                }
                .disabled(!isReachable)
            }
            creationRow
        } header: {
            HStack {
                Text(mac.name)
                Spacer()
                Text(isReachable ? "Online" : "Unavailable")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var creationRow: some View {
        Button(action: onCreate) {
            HStack {
                Label("New Session", systemImage: "plus")
                Spacer()
                if model.creatingMacID == mac.id {
                    ProgressView().controlSize(.small)
                }
            }
            .contentShape(.rect)
        }
        .disabled(!isReachable || model.creatingMacID != nil)
    }
}

private struct CreatedSessionDestination: Identifiable, Hashable {
    let mac: RemoteMac
    let session: RemoteCatalogSession

    var id: String { "\(mac.id):\(session.sessionID)" }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private struct SessionRow: View {
    let session: RemoteCatalogSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.title).font(.headline)
                if session.runningCommand != nil {
                    ProgressView().controlSize(.small)
                }
            }
            Text(session.cwd)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}

private struct MobileSessionView: View {
    let model: MobileRemoteModel
    let session: RemoteCatalogSession
    let mac: RemoteMac
    @State private var command = ""

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            if showsTerminal {
                VaulttyTerminalView(chunks: model.chunks) { model.sendInput($0) }
                    .background(.black)
            } else {
                blockTranscript
            }
            inputBar
            if showsTerminal { keyStrip }
        }
        .background(.black)
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .onDisappear { model.detach() }
    }

    private var showsTerminal: Bool {
        model.transcript.isAlternateScreenActive
    }

    private var blockTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.transcript.blocks.isEmpty {
                        ContentUnavailableView(
                            "No commands yet",
                            systemImage: "terminal",
                            description: Text("Run a command here or on a connected Mac.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 320)
                    }
                    ForEach(model.transcript.blocks) { block in
                        MobileBlockView(block: block)
                            .id(block.id)
                    }
                }
                .padding(12)
            }
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .background(.black)
            .onChange(of: model.transcript.revision) { _, _ in
                guard let id = model.transcript.blocks.last?.id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.connectionState == .attached ? .green : .orange)
                .frame(width: 7, height: 7)
            Text(statusText)
            Spacer()
            Label("\(model.presenceCount)", systemImage: "keyboard")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            if showsTerminal {
                Button("Show Keyboard", systemImage: "keyboard") {
                    NotificationCenter.default.post(name: .vaulttyFocusTerminal, object: nil)
                }
                .frame(maxWidth: .infinity)
            } else {
                TextField("Command", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .onSubmit {
                        guard !command.isEmpty else { return }
                        model.submit(command)
                        command = ""
                    }
            }
            Menu {
                Button("Interrupt  ⌃C", systemImage: "stop.fill") {
                    model.interrupt()
                }
                Button("End Input  ⌃D", systemImage: "eject.fill") {
                    model.sendInput(Data([0x04]))
                }
                Divider()
                Button("Escape  ⌃[", systemImage: "escape") {
                    model.sendInput(Data([0x1b]))
                }
                Button("Clear Screen  ⌃L", systemImage: "rectangle.on.rectangle.slash") {
                    model.sendInput(Data([0x0c]))
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Terminal Actions")
        }
        .padding(8)
        .background(.bar)
    }

    private var keyStrip: some View {
        HStack(spacing: 4) {
            TerminalKey("Esc", bytes: [0x1b], model: model)
            TerminalKey("Ctrl-C", bytes: [0x03], model: model)
            TerminalKey("Tab", bytes: [0x09], model: model)
            TerminalKey("←", bytes: Array("\u{1b}[D".utf8), model: model)
            TerminalKey("↑", bytes: Array("\u{1b}[A".utf8), model: model)
            TerminalKey("↓", bytes: Array("\u{1b}[B".utf8), model: model)
            TerminalKey("→", bytes: Array("\u{1b}[C".utf8), model: model)
            Button("Dismiss", systemImage: "keyboard.chevron.compact.down") {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil,
                    from: nil,
                    for: nil
                )
            }
            .labelStyle(.iconOnly)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .font(.caption.monospaced())
        .padding(.horizontal, 4)
        .background(.bar)
    }

    private var statusText: String {
        switch model.connectionState {
        case .idle: "Detached"
        case .authenticating: "Authenticating"
        case .connecting: "Connecting"
        case .attached: mac.name
        case .reconnecting: "Reconnecting"
        case .failed(let message): message
        }
    }
}

private struct MobileBlockView: View {
    let block: VaulttyBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("❯")
                    .foregroundStyle(.green)
                Text(block.command)
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                state
            }
            .font(.body.monospaced())

            if !block.output.isEmpty {
                Text(block.output)
                    .font(.callout.monospaced())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let cwd = block.cwd {
                Text(cwd)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var state: some View {
        switch block.state {
        case .running:
            ProgressView().controlSize(.small)
        case .completed(0):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .completed(let status):
            Text("exit \(status)")
                .font(.caption.monospaced())
                .foregroundStyle(.red)
        }
    }
}

private struct TerminalKey: View {
    let title: String
    let bytes: [UInt8]
    let model: MobileRemoteModel

    init(_ title: String, bytes: [UInt8], model: MobileRemoteModel) {
        self.title = title
        self.bytes = bytes
        self.model = model
    }

    var body: some View {
        Button(title) { model.sendInput(Data(bytes)) }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(.rect)
    }
}

private struct VaulttyTerminalView: UIViewRepresentable {
    let chunks: [TerminalChunk]
    let onInput: (Data) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput)
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.backgroundColor = .black
        context.coordinator.terminalView = view
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.focusTerminal),
            name: .vaulttyFocusTerminal,
            object: nil
        )
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        context.coordinator.onInput = onInput
        for chunk in chunks where chunk.id > context.coordinator.lastChunkID {
            view.feed(byteArray: Array(chunk.data)[...])
            context.coordinator.lastChunkID = chunk.id
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var onInput: (Data) -> Void
        var lastChunkID: UInt64 = 0
        weak var terminalView: TerminalView?

        init(onInput: @escaping (Data) -> Void) {
            self.onInput = onInput
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @MainActor @objc func focusTerminal() {
            _ = terminalView?.becomeFirstResponder()
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) { onInput(Data(data)) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

private struct MobilePaywall: View {
    let store: MobileStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 54))
                Text("One terminal everywhere")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("Attach securely to every open InfiniTerm session on your Macs. Includes a 14-day free trial.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if store.isLoading {
                    ProgressView("Loading subscriptions…")
                } else if store.products.isEmpty {
                    VStack(spacing: 8) {
                        Text("Subscriptions are temporarily unavailable.")
                            .foregroundStyle(.secondary)
                        Button("Try Again") {
                            Task { await store.load() }
                        }
                    }
                } else {
                    ForEach(store.products, id: \.id) { product in
                        Button {
                            Task { await store.purchase(product) }
                        } label: {
                            HStack {
                                Text(product.id == MobileStore.annualProductID ? "Annual" : "Monthly")
                                Spacer()
                                Text(product.displayPrice)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
                if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Button("Restore Purchases") { Task { await store.restore() } }
            }
            .padding(24)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onChange(of: store.hasEntitlement) { _, entitled in
                if entitled { dismiss() }
            }
        }
    }
}

private struct LockedView: View {
    let unlock: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill").font(.system(size: 52))
            Text("InfiniTerm is locked").font(.title.bold())
            Button("Unlock", action: unlock).buttonStyle(.borderedProminent)
        }
    }
}

private extension Notification.Name {
    static let vaulttyFocusTerminal = Notification.Name("VaulttyFocusTerminal")
}
#endif

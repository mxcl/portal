#if os(macOS)
import AppKit
import Testing
@testable import PortalTerminal
@testable import PortalTerminalApp

@Suite("Embedded terminal", .serialized)
struct TerminalIntegrationTests {
    @Test(arguments: [false, true]) @MainActor
    func outputOnlyFollowsWhenAlreadyAtBottom(startsAtBottom: Bool) async {
        #expect(await TerminalViewController.outputScrollingSelfTest(startsAtBottom: startsAtBottom))
    }

    @Test(arguments: [false, true]) @MainActor
    func externalBranchSwitchUpdatesStatusWithGitTreeHidden(standalone: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", directory.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        try git(["init", "--initial-branch=before"])
        try git(["-c", "user.name=Test", "-c", "user.email=test@example.com",
                 "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Initial"])
        let updated = try await TerminalViewController.externalBranchChangeSelfTest(
            directory: directory, standalone: standalone
        ) {
            try git(["switch", "-c", "after"])
        }
        #expect(updated)
    }

    @Test @MainActor func referenceInsertionPreservesDraftAndRejectsBusySessions() {
        #expect(TerminalViewController.referenceInsertionSelfTest())
    }

    @Test @MainActor func startupStatusMatchesSessionIntent() {
        let statuses = TerminalViewController.sessionStartupStatusesSelfTest()
        #expect(statuses.count == 5)
        for (actual, expected) in zip(statuses, [
            "Starting shell...", "Rejoining session...", "Starting shell...",
            "Starting shell...", "Rejoining session..."
        ]) {
            #expect(actual.hasSuffix(expected))
        }
    }

    @Test @MainActor func palettePrefillsExactSessionWithoutSubmittingAndRejectsBusySessions() {
        #expect(TerminalViewController.paletteCommandPrefillSelfTest())
    }

    @Test @MainActor func standaloneWindowOpensAtUsableSize() throws {
        let application = NSApplication.shared
        let workspace = TerminalWorkspace()
        workspace.newWindow(directory: FileManager.default.temporaryDirectory, hosts: [])
        let window = try #require(application.windows.first { $0 is StandaloneTerminalWindow })
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()

        let size = try #require(window.contentView?.bounds.size)
        #expect(size.width >= 760)
        #expect(size.height >= 480)
        let borders = try #require(window.contentViewController?.view.subviews.compactMap { $0 as? TrafficLightBorderView }.first)
        #expect(borders.buttonFrames.count == 3)
        #expect(borders.material == .hudWindow)
        #expect(borders.maskImage != nil)
        #expect(borders.hitTest(.zero) == nil)


        let root = try #require(window.contentViewController?.view)
        let material = try #require(root.subviews.first { $0 is NSVisualEffectView })
        func scrollViews(in view: NSView) -> [NSScrollView] {
            view.subviews.flatMap { child in
                (child as? NSScrollView).map { [$0] } ?? scrollViews(in: child)
            }
        }
        let scroll = try #require(scrollViews(in: root).max { $0.frame.height < $1.frame.height })
        #expect(material.convert(material.bounds, to: nil).maxY == window.frame.height)
        #expect(scroll.convert(scroll.bounds, to: nil).maxY == window.frame.height)
    }

    @Test @MainActor func standaloneWindowFollowsApplicationAppearance() throws {
        let application = NSApplication.shared
        let originalAppearance = application.appearance
        defer { application.appearance = originalAppearance }
        application.appearance = NSAppearance(named: .darkAqua)

        let workspace = TerminalWorkspace()
        workspace.newWindow(directory: FileManager.default.temporaryDirectory, hosts: [])
        let window = try #require(application.windows.first { $0 is StandaloneTerminalWindow })
        defer { window.close() }

        #expect(window.appearance == nil)
        #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        #expect(window.contentViewController?.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)

        application.appearance = NSAppearance(named: .aqua)
        #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
        #expect(window.contentViewController?.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
    }

    private actor InventoryLoads {
        var count = 0
        func load(succeeds: Bool) -> [SessionPickerCandidate]? {
            count += 1
            return succeeds ? [] : nil
        }
    }

    @Test(arguments: [true, false]) @MainActor
    func idleSessionPickerDoesNotPoll(succeeds: Bool) async throws {
        let loads = InventoryLoads()
        let picker = SessionPickerModel()
        defer { picker.invalidate() }
        picker.refresh(initial: [], excluding: [], homeDirectory: "/tmp",
            loadLocal: { [] }, loadRemote: { await loads.load(succeeds: succeeds) },
            isAvailable: { _ in true }, onUpdate: { _ in })
        try await Task.sleep(for: .milliseconds(2300))
        #expect(await loads.count == 1)
    }

    @Test @MainActor func projectActivityTracksRunningAndUnviewedTerminals() {
        #expect(TerminalViewController.projectActivitySelfTest())
    }

    @Test @MainActor func untouchedSessionsAreDiscardedWithoutReplacingThem() {
        #expect(TerminalViewController.untouchedSessionCleanupSelfTest())
    }

    @Test @MainActor func commandBlocksStayCompactAfterViewportChanges() {
        #expect(portalBlockWidthReflowSelfTest())
    }

    @Test(arguments: [CGFloat(0), 38], [CGFloat(-10), 80, -400]) @MainActor
    func findResultsClearStickyHeaders(topInset: CGFloat, startingOffset: CGFloat) {
        #expect(portalFindScrollClearanceSelfTest(topInset: topInset, startingOffset: startingOffset))
    }

    @Test @MainActor func commandHeadersStickWithinTheirBlock() {
        #expect(portalStickyBlockHeaderSelfTest())
    }

    @Test @MainActor func commandBarOverlaysHistoryWithoutHidingItsEnd() async {
        #expect(await portalCommandBarOverlaySelfTest())
    }

    @Test @MainActor func toolbarDoesNotExtendMinimumScrollRegion() {
        #expect(portalToolbarScrollRegionSelfTest())
    }

    @Test @MainActor func detachedBlockColorsFollowAppearance() {
        #expect(portalDetachedBlockAppearanceSelfTest())
    }

    @Test @MainActor func failedCommandDividers() {
        #expect(portalFailedCommandDividersSelfTest())
    }

    @Test func configuredDestinationsAppearBeforeRemoteInventory() {
        let hosts = ["pangolin", "atlas"].map {
            TerminalHost(id: $0, name: $0, peer: $0, helperPath: "/helper", directory: "/projects")
        }
        let snapshot = SessionPickerSnapshot(sections: []).offeringNewSessions(on: hosts)
        #expect(snapshot.sections.map(\.location) == [.sshHost("atlas"), .sshHost("pangolin"), .local])
        #expect(snapshot.sections.filter { $0.location != .local }.allSatisfy { $0.newSession?.action == .create && $0.items.isEmpty })
        #expect(snapshot.offeringNewSessions(on: hosts) == snapshot)
    }

    @Test @MainActor func hostLoadingCompletesIndependentlyWithoutReordering() async throws {
        let hosts = ["zebra", "alpha"].map {
            TerminalHost(id: $0, name: $0, peer: $0, helperPath: "/helper", directory: "/tmp")
        }
        let picker = SessionPickerModel()
        defer { picker.invalidate() }
        var updates: [SessionPickerSnapshot] = []
        picker.refresh(initial: [], excluding: [], homeDirectory: "/tmp",
            loadLocal: { [] }, remoteLoaders: [
                .sshHost("zebra"): { [] },
                .sshHost("alpha"): {
                    try? await Task.sleep(for: .milliseconds(150))
                    return nil
                }
            ], isAvailable: { _ in true }, onUpdate: {
                updates.append($0.offeringNewSessions(on: hosts))
            })
        for _ in 0..<100 where updates.last?.loadingLocations.isEmpty != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(updates.first?.loadingLocations == [.local, .sshHost("zebra"), .sshHost("alpha")])
        #expect(updates.contains { $0.loadingLocations == [.sshHost("alpha")] })
        #expect(updates.last?.loadingLocations.isEmpty == true)
        #expect(updates.allSatisfy { $0.sections.map(\.location) == [.sshHost("alpha"), .sshHost("zebra"), .local] })
    }

    @Test @MainActor func standaloneRestoresTabGroupsAndOmitsClosedTabs() throws {
        let application = NSApplication.shared
        let suite = "PortalTerminalTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = TerminalWorkspace()
        workspace.newWindow(directory: URL(fileURLWithPath: "/tmp"))
        defer {
            for window in application.windows where window is StandaloneTerminalWindow { window.close() }
        }
        let first = try #require(application.windows.first { $0 is StandaloneTerminalWindow })
        workspace.newTab(in: first)
        let second = try #require(first.tabGroup?.windows.first { $0 !== first })
        workspace.newTab(in: second)
        let closed = try #require(first.tabGroup?.windows.first { $0 !== first && $0 !== second })
        closed.close()
        first.tabGroup?.selectedWindow = first
        workspace.saveWindows(defaults: defaults)
        let data = try #require(defaults.data(forKey: "standaloneTerminalWindows"))
        let saved = try JSONDecoder().decode([TerminalWorkspace.SavedWindow].self, from: data)
        #expect(saved.count == 1)
        #expect(saved.first?.tabs.count == 2)
        #expect(saved.first?.selectedIndex == 0)
        first.close()
        second.close()
        let restored = TerminalWorkspace()
        #expect(restored.restoreWindows(hosts: [], defaults: defaults))
        let restoredWindow = try #require(application.windows.first { $0 is StandaloneTerminalWindow && $0 !== first && $0 !== second && $0 !== closed })
        #expect(restoredWindow.tabGroup?.windows.count == 2)
        #expect(restoredWindow.tabGroup?.selectedWindow === restoredWindow.tabGroup?.windows.first)
        for window in application.windows where window is StandaloneTerminalWindow { window.close() }
        restored.saveWindows(defaults: defaults)
        #expect(!TerminalWorkspace().restoreWindows(hosts: [], defaults: defaults))
    }

    @Test @MainActor func directoryOpenSkipsSessionPicker() async throws {
        let application = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
        let delegate = TerminalDelegate()
        defer {
            for window in application.windows where window is StandaloneTerminalWindow { window.close() }
        }
        delegate.application(application, open: [directory])
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        for _ in 0..<100 {
            if application.windows.contains(where: { $0 is StandaloneTerminalWindow }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let windows = application.windows.filter { $0 is StandaloneTerminalWindow }
        #expect(windows.count == 1)
        let controller = try #require(windows.first?.contentViewController as? TerminalViewController)
        #expect(controller.windowDirectory.standardizedFileURL == directory.standardizedFileURL)
        #expect(!controller.isShowingSessionPicker)
    }

    @Test @MainActor func initialReopenRestoresSavedTabs() async throws {
        let application = NSApplication.shared
        let key = "standaloneTerminalWindows"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            UserDefaults.standard.set(previous, forKey: key)
            for window in application.windows where window is StandaloneTerminalWindow { window.close() }
        }
        let saved = [TerminalWorkspace.SavedWindow(tabs: [
            .init(session: nil, directory: URL(fileURLWithPath: "/tmp"), hostID: nil),
            .init(session: nil, directory: URL(fileURLWithPath: "/tmp"), hostID: nil)
        ], selectedIndex: 0, frame: "{{0, 0}, {1120, 760}}")]
        UserDefaults.standard.set(try JSONEncoder().encode(saved), forKey: key)
        let delegate = TerminalDelegate()
        _ = delegate.applicationShouldHandleReopen(application, hasVisibleWindows: false)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        for _ in 0..<100 {
            if application.windows.contains(where: { $0 is StandaloneTerminalWindow }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let window = try #require(application.windows.first { $0 is StandaloneTerminalWindow })
        #expect(window.tabGroup?.windows.count == 2)
    }

    @Test(arguments: [false, true]) @MainActor
    func standalonePickerExcludesOtherNativeTabs(separateWindow: Bool) throws {
        let application = NSApplication.shared
        let workspace = TerminalWorkspace()
        workspace.newWindow(directory: URL(fileURLWithPath: "/tmp"))
        defer {
            for window in application.windows where window is StandaloneTerminalWindow { window.close() }
        }
        let first = try #require(application.windows.first { $0 is StandaloneTerminalWindow })
        let firstController = try #require(first.contentViewController as? TerminalViewController)
        let session = try #require(firstController.activeSessionRef)
        if separateWindow {
            workspace.newWindow(directory: URL(fileURLWithPath: "/tmp"))
        } else {
            workspace.newTab(in: first)
        }
        let second = try #require(application.windows.first { $0 is StandaloneTerminalWindow && $0 !== first })
        let pickerController = try #require(second.contentViewController as? TerminalViewController)
        #expect(pickerController.sessionPickerExclusions.contains(session))
        first.close()
        #expect(!pickerController.sessionPickerExclusions.contains(session))
    }

    @Test @MainActor func standaloneUsesPortalBlurMaterial() {
        let root = TahoeGlassRootView()
        let material = root.subviews.compactMap { $0 as? NSVisualEffectView }.first!
        #expect(material.blendingMode == .withinWindow)
        root.usesPortalMaterials = true
        #expect(material.blendingMode == .behindWindow)
        #expect(material.material == .underWindowBackground)
    }

    @Test @MainActor func standaloneLightBackgroundExposesBlurMaterial() {
        let root = TahoeGlassRootView()
        root.appearance = NSAppearance(named: .aqua)
        root.usesPortalMaterials = true
        for effect in BackgroundBlurEffect.allCases {
            root.backgroundBlurEffect = effect
            root.viewDidChangeEffectiveAppearance()
            root.effectiveAppearance.performAsCurrentDrawingAppearance {
                #expect(root.subviews.last?.layer?.backgroundColor == TahoeGlassPalette.standaloneSpaceBackground.cgColor)
                #expect((root.subviews.last?.layer?.backgroundColor?.alpha ?? 1) < 0.1)
                #expect(TahoeGlassPalette.standaloneCommandBackground(darkOpacity: 0.22).cgColor == NSColor.textBackgroundColor.withAlphaComponent(0.18).cgColor)
                #expect(TahoeGlassPalette.standaloneCommandBackground(darkOpacity: 0.18).cgColor == NSColor.textBackgroundColor.withAlphaComponent(0.18).cgColor)
            }
        }
    }

    @Test @MainActor func embeddedDarkBackgroundInheritsSwiftUISurface() {
        let root = TahoeGlassRootView()
        root.appearance = NSAppearance(named: .darkAqua)
        for effect in BackgroundBlurEffect.allCases {
            root.backgroundBlurEffect = effect
            root.viewDidChangeEffectiveAppearance()
            root.effectiveAppearance.performAsCurrentDrawingAppearance {
                let expected = NSColor.clear.cgColor
                let tint = root.subviews.last!
                #expect(tint.layer?.backgroundColor == expected)
                #expect(tint.layer?.sublayers?.first?.isHidden == true)
                #expect(TahoeGlassPalette.commandBackground.cgColor == expected)
                #expect(root.subviews.dropLast().allSatisfy { $0.isHidden })
            }
        }
        root.usesPortalMaterials = true
        root.backgroundBlurEffect = .original
        #expect(root.subviews.last?.layer?.sublayers?.first?.isHidden == false)
    }

    @Test @MainActor func standalonePickerIncludesAttachedProjectSessions() {
        let controller = TerminalViewController(standalone: true)
        let project = SessionPickerCandidate(sessionRef: .local("project"), hostTitle: "This Mac",
            title: "Project", cwd: "/tmp/project", isClosed: false, commandCount: 1,
            commandHistory: [], action: .attach, attachedClientCount: 1)
        let inventory = SessionPickerModel.Inventory()
        inventory.local = [project]
        let picker = SessionPickerModel(inventory: inventory)
        var items: [SessionPickerItem] = []
        picker.refresh(initial: [], excluding: controller.sessionPickerExclusions,
            homeDirectory: "/tmp", loadLocal: { [project] }, loadRemote: { [] },
            isAvailable: { _ in true }, onUpdate: { items = $0.sections.flatMap(\.items) })
        #expect(items.map(\.candidate.sessionRef) == [.local("project")])
        picker.invalidate()
    }

    @Test func sshWindowLaunchRoundTripsHostIdentity() {
        let id = "host with spaces & symbols/東京"
        #expect(TerminalLaunchRequest.hostID(from: TerminalLaunchRequest.url(hostID: id)) == id)
        #expect(TerminalLaunchRequest.hostID(from: URL(string: "https://new-window?host=elsewhere")!) == nil)
        #expect(TerminalLaunchRequest.hostID(from: URL(string: "portal-terminal://new-window?host=")!) == nil)
    }

    @Test @MainActor func nativeTabsStartHiddenAndCanBeReopened() throws {
        let application = NSApplication.shared
        let workspace = TerminalWorkspace()
        workspace.newWindow(directory: FileManager.default.temporaryDirectory)
        let first = try #require(application.windows.first { $0 is StandaloneTerminalWindow })
        defer {
            for window in application.windows where window is StandaloneTerminalWindow { window.close() }
        }
        #expect(first.titleVisibility == .hidden)
        #expect(first.tabGroup?.isTabBarVisible != true)
        first.makeKeyAndOrderFront(nil)
        let newTabKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: first.windowNumber,
            context: nil, characters: "t", charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17))
        #expect(first.performKeyEquivalent(with: newTabKey))
        let group = try #require(first.tabGroup)
        #expect(group.windows.count == 2)
        #expect(group.isTabBarVisible)
        let selected = try #require(group.selectedWindow)
        selected.title = "~"
        first.title = "git-sync"
        selected.contentView?.superview?.layoutSubtreeIfNeeded()
        let strip = try #require(selected.titlebarAccessoryViewControllers.last)
        #expect(strip.layoutAttribute == .right)
        let material = try #require(strip.view.subviews.compactMap { $0 as? NSVisualEffectView }.first)
        #expect(material.material == .hudWindow)
        #expect(material.blendingMode == .withinWindow)
        #expect(material.hitTest(.zero) == nil)

        #expect(strip.view.frame.width < selected.frame.width / 2)
        let rect = strip.view.convert(strip.view.bounds, to: nil)
        #expect(abs(rect.midX - selected.frame.width / 2) < 1)
        let close = try #require(selected.standardWindowButton(.closeButton))
        let closeRect = close.convert(close.bounds, to: nil)
        #expect(abs(rect.midY - closeRect.midY) < 4)
        let originalSize = selected.frame.size
        for width in [760.0, 1440.0] {
            selected.setFrame(NSRect(origin: selected.frame.origin, size: NSSize(width: width, height: originalSize.height)), display: true)
            selected.contentView?.superview?.layoutSubtreeIfNeeded()
            let resized = strip.view.convert(strip.view.bounds, to: nil)
            #expect(abs(resized.midX - width / 2) < 1)
            #expect(resized.width < width - 200)
        }
        selected.setFrame(NSRect(origin: selected.frame.origin, size: originalSize), display: true)
        group.selectedWindow = first
        first.makeKeyAndOrderFront(nil)
        first.contentView?.superview?.layoutSubtreeIfNeeded()
        let switchedStrip = try #require(first.titlebarAccessoryViewControllers.last)
        #expect(switchedStrip.layoutAttribute == .right)
        #expect(abs(switchedStrip.view.convert(switchedStrip.view.bounds, to: nil).midX - first.frame.width / 2) < 1)
        group.selectedWindow = selected

        let second = try #require(group.windows.first { $0 !== first })
        #expect((second.contentViewController as? TerminalViewController)?.windowDirectory == FileManager.default.homeDirectoryForCurrentUser)
        let closeTabKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: second.windowNumber,
            context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        #expect(second.performKeyEquivalent(with: closeTabKey))
        #expect(!second.isVisible)
        #expect(first.isVisible)
        #expect(first.tabGroup?.isTabBarVisible != true)
        #expect(workspace.canReopenClosedTab)
        first.makeKeyAndOrderFront(nil)
        workspace.reopenClosedTab(in: first)
        #expect(first.tabGroup?.windows.count == 2)
        #expect(!workspace.canReopenClosedTab)
        workspace.newWindow()
        #expect(first.tabGroup?.windows.count == 2)
    }

    @Test @MainActor func rendererAndCompletions() {
        Ansi.runSelfTests()
        #expect(Ansi.terminalScreenScrollRegionSelfTest())
        #expect(Ansi.terminalScreenFixedHeightSelfTest())
        #expect(Ansi.terminalScreenDeferredWrapSelfTest())
        #expect(TerminalOutputProcessor.alternateScreenTranscriptSelfTest())
        #expect(TerminalOutputProcessor.terminalSizeProbeSelfTest())
        #expect(TerminalOutputProcessor.terminalResponsesAreImmediateSelfTest())
        #expect(TerminalOutputProcessor.inputFeedbackPrioritySelfTest())
        #expect(TerminalOutputProcessor.truncatedHistoryReplaySelfTest())
        #expect(PortalCompletionEngine.calculatorCompletionSelfTest())
        #expect(PortalCompletionEngine.historyMergePrefixSelfTest())
        #expect(ShellCompletionParser.midTokenReplacementRangeSelfTest())
    }

    @Test @MainActor func terminalColorsFollowAppearance() throws {
        let output = Ansi.StyledTextRenderer().process("\u{1B}[93mY\u{1B}[38;2;12;34;56mR").attributedText
        let yellow = try #require(output.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let rgb = try #require(output.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor)
        var colors: [NSColor] = []
        var surfaces: [NSColor] = []
        var emptyBackgrounds: [NSColor] = []
        var explicitColors: [NSColor] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                colors.append(yellow.usingColorSpace(.sRGB)!)
                surfaces.append(TahoeGlassPalette.commandBackground.usingColorSpace(.sRGB)!)
                emptyBackgrounds.append(TahoeGlassPalette.emptyBackground.usingColorSpace(.sRGB)!)
                let failure = TahoeGlassPalette.failedCommandBackground.usingColorSpace(.sRGB)!
                #expect(failure.alphaComponent == 1)
                #expect(failure.redComponent > failure.greenComponent)
                #expect(failure != surfaces.last!)
                explicitColors.append(rgb.usingColorSpace(.sRGB)!)
            }
        }
        #expect(colors[0].greenComponent < 0.5)
        #expect(colors[1].greenComponent > 0.9)
        #expect(surfaces[0].alphaComponent == 1)
        #expect(surfaces[1].alphaComponent == 0)
        #expect(emptyBackgrounds[0].redComponent > 0.95)
        #expect(emptyBackgrounds[0].alphaComponent == 1)
        #expect(emptyBackgrounds[1].alphaComponent == 0)
        #expect(surfaces[0].redComponent > 0.95)
        #expect(surfaces[1].redComponent < 0.25)
        #expect(explicitColors[0] == explicitColors[1])
    }

    @Test func processExitDrainsOutput() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf 'READY 0\\nEXIT 0\\n'"]
        let queue = DispatchQueue(label: "terminal-exit-test")
        let transport = ProcessSessionTransport(queue: queue, process: process, write: { _, _ in })
        let output = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            queue.async {
                var output = ""
                transport.onText = { output += $0 }
                transport.onExit = { _ in continuation.resume(returning: output) }
                do { try transport.start() }
                catch { continuation.resume(throwing: error) }
            }
        }
        transport.close(terminate: false)
        #expect(output == "READY 0\nEXIT 0\n")
    }

    @Test func reconnectNeverStartsAnotherShell() {
        let current = PtySession.reattachCommand(version: 2, clientID: "client", sessionID: "session")
        #expect(SessionWireProtocol.encode(current) == "JOIN2 2 mac Y2xpZW50 c2Vzc2lvbg==")
        let previous = SessionWireProtocol.encode(PtySession.reattachCommand(version: 1, clientID: "client", sessionID: "session"))
        let fields = previous.split(separator: " ")
        #expect(String(data: Data(base64Encoded: String(fields[3]))!, encoding: .utf8) == "/usr/bin/false")
    }

    @Test func historyRetainsMarkersAcrossChunkSplits() {
        let stream = "before\u{1B}]133;C;ZWNobyBoaQ==\u{7}hi\n\u{1B}]133;D;0\u{7}"
        for split in 0...stream.count {
            var parser = PortalMarkerParser()
            let events = parser.consume(String(stream.prefix(split))) + parser.consume(String(stream.dropFirst(split)))
            let markers = events.compactMap { event -> PortalMarker.Kind? in
                if case .marker(let marker) = event { return marker.kind }; return nil
            }
            #expect(markers == [.commandStarted(command: "echo hi"), .commandFinished(status: 0)])
        }
        #expect(TerminalHistory.normalizedReplay(" 0% [---]\nlog\n\u{1B}]133;C;") == "log\n\u{1B}]133;C;")
    }
}

#endif

#if os(macOS)
import AppKit
import Testing
@testable import PortalTerminal

@Suite("Embedded terminal", .serialized)
struct TerminalIntegrationTests {
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
        #expect(Set(snapshot.sections.map(\.title)) == ["pangolin", "atlas"])
        #expect(snapshot.sections.allSatisfy { $0.newSession?.action == .create && $0.items.isEmpty })
        #expect(snapshot.offeringNewSessions(on: hosts) == snapshot)
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

    @Test @MainActor func standaloneCannotEnterTabSession() {
        let controller = TerminalViewController(standalone: true)
        controller.enterTabSession()
        #expect(!controller.isTabSession)
        controller.newTab(nil)
        #expect(!controller.isViewLoaded)
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

    @Test @MainActor func tabBarStartsHidden() {
        let controller = TerminalViewController()
        #expect(!controller.isTabSession)
        controller.enterTabSession()
        #expect(controller.isTabSession)
        #expect(!controller.isViewLoaded)
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

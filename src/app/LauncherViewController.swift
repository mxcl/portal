import AppKit
import CoreImage.CIFilterBuiltins
import Foundation
import MetalKit
import QuartzCore

enum PortalLauncherAppearance {
    static let effectOutset: CGFloat = 14
}

@MainActor
private final class PortalTendrilView: MTKView, MTKViewDelegate {
    private struct Uniforms {
        var size: SIMD2<Float>
        var pointer: SIMD2<Float>
        var time: Float
        var excite: Float
    }

    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var tracking: NSTrackingArea?
    private var pointer = SIMD2<Float>(repeating: -1)
    private var targetExcite: Float = 0
    private var excite: Float = 0
    private let startedAt = CACurrentMediaTime()

    init() {
        let metalDevice = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: metalDevice)
        guard let metalDevice else {
            isHidden = true
            return
        }

        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        framebufferOnly = true
        preferredFramesPerSecond = 30
        enableSetNeedsDisplay = false
        isPaused = false
        layer?.isOpaque = false

        let descriptor = MTLRenderPipelineDescriptor()
        if let library = try? metalDevice.makeLibrary(source: Self.shaderSource, options: nil) {
            descriptor.vertexFunction = library.makeFunction(name: "portalVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "portalFragment")
        }
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        commandQueue = metalDevice.makeCommandQueue()
        pipeline = try? metalDevice.makeRenderPipelineState(descriptor: descriptor)
        delegate = self

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        updateMotion()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { needsDisplay = true }
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        tracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return }
        pointer = SIMD2(Float(location.x / bounds.width), Float(location.y / bounds.height))
        targetExcite = 1
    }

    override func mouseExited(with event: NSEvent) {
        targetExcite = 0
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline, let commandQueue, let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable, bounds.width > 0, bounds.height > 0,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        excite += (targetExcite - excite) * 0.07
        var uniforms = Uniforms(
            size: SIMD2(Float(bounds.width), Float(bounds.height)),
            pointer: pointer,
            time: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? 2.4
                : Float(CACurrentMediaTime() - startedAt),
            excite: excite
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    static func rendererSelfTest() -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return (try? device.makeLibrary(source: shaderSource, options: nil)) != nil
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        updateMotion()
    }

    private func updateMotion() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        isPaused = reduceMotion
        enableSetNeedsDisplay = reduceMotion
        if reduceMotion { needsDisplay = true }
    }

    private static let shaderSource = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct Uniforms {
        float2 size;
        float2 pointer;
        float time;
        float excite;
    };

    vertex VertexOut portalVertex(uint id [[vertex_id]]) {
        const float2 positions[4] = {
            float2(-1.0, -1.0), float2(1.0, -1.0),
            float2(-1.0, 1.0), float2(1.0, 1.0)
        };
        VertexOut out;
        out.position = float4(positions[id], 0.0, 1.0);
        out.uv = positions[id] * 0.5 + 0.5;
        return out;
    }

    float hash21(float2 p) {
        return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
    }

    float noise21(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        return mix(
            mix(hash21(i), hash21(i + float2(1.0, 0.0)), f.x),
            mix(hash21(i + float2(0.0, 1.0)), hash21(i + 1.0), f.x),
            f.y
        );
    }

    float fbm(float2 p) {
        float value = 0.0;
        float weight = 0.5;
        for (int i = 0; i < 4; i++) {
            value += weight * noise21(p);
            p = p * 2.03 + 17.1;
            weight *= 0.5;
        }
        return value;
    }

    float roundedBoxDistance(float2 p, float2 halfSize, float radius) {
        float2 q = abs(p) - halfSize + radius;
        return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
    }

    fragment float4 portalFragment(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        float2 p = (in.uv - 0.5) * u.size;
        float2 halfSize = max(u.size * 0.5 - 14.0, float2(20.0));
        float distance = roundedBoxDistance(p, halfSize, 18.0);
        float2 q = p / halfSize;
        float angle = atan2(q.y, q.x);
        float turn = angle / 6.2831853 + 0.5;
        float cursor = exp(-length(in.uv - u.pointer) * 11.0) * u.excite;
        float time = u.time * 0.42;

        float flow = fbm(float2(angle * 1.8 - time * 0.34, time * 0.11));
        float fine = noise21(float2(angle * 7.0 + time * 0.8, time * 0.23));
        float warp = (flow - 0.5) * (5.2 + cursor * 5.0);

        float core = exp(-abs(distance - warp) * 0.95);
        float threadA = exp(-abs(distance - 3.2 - sin(angle * 5.0 - time * 1.7) * 1.4) * 1.65);
        float threadB = exp(-abs(distance + 2.7 - sin(angle * 7.0 + time * 1.15) * 1.1) * 1.85);

        float pulseA = pow(max(0.0, sin(angle * 9.0 - time * 4.2 + flow * 5.0)), 12.0);
        float pulseB = pow(max(0.0, sin(angle * 13.0 + time * 3.1 + fine * 4.0)), 16.0);
        float outer = exp(-abs(distance - 6.6 - (fine - 0.5) * 8.0) * 0.82)
            * (pulseA + pulseB) * 0.9;
        float wispFade = 1.0 - smoothstep(7.0, 13.5, distance);
        float wisps = exp(-abs(distance - 9.0 - (flow - 0.5) * 12.0) * 0.5)
            * (pulseA * 0.75 + pulseB * 0.55) * wispFade;

        float stillTime = u.time * 0.08;
        float ringNoise = fbm(float2(angle * 9.0 + stillTime * 0.11, stillTime * 0.17));
        float ringDrift = (ringNoise - 0.5) * 0.65;
        float ringA = exp(-abs(distance + 5.7 - ringDrift - sin(angle * 3.0 + stillTime * 0.41) * 0.18) * 2.4) * 0.30;
        float ringB = exp(-abs(distance + 3.4 - ringDrift - sin(angle * 5.0 - stillTime * 0.29) * 0.16) * 2.55) * 0.28;
        float ringC = exp(-abs(distance + 1.1 - ringDrift - sin(angle * 4.0 + stillTime * 0.23) * 0.20) * 2.35) * 0.31;
        float ringD = exp(-abs(distance - 1.2 - ringDrift - sin(angle * 6.0 - stillTime * 0.19) * 0.17) * 2.5) * 0.27;
        float ringE = exp(-abs(distance - 3.5 - ringDrift - sin(angle * 2.0 + stillTime * 0.31) * 0.24) * 2.3) * 0.29;
        float ringF = exp(-abs(distance - 5.8 - ringDrift - sin(angle * 3.0 - stillTime * 0.17) * 0.28) * 2.15) * 0.25;
        float rings = ringA + ringB + ringC + ringD + ringE + ringF;
        float3 ringColor = ringA * float3(0.05, 0.63, 1.0)
            + ringB * float3(0.15, 0.54, 1.0)
            + ringC * float3(0.33, 0.43, 1.0)
            + ringD * float3(0.55, 0.32, 1.0)
            + ringE * float3(0.76, 0.22, 1.0)
            + ringF * float3(0.93, 0.12, 1.0);
        float fuzzNoise = pow(noise21(float2(turn * 110.0 + stillTime * 0.13, distance * 1.3 - stillTime * 0.19)), 4.0);
        float ringFuzz = (exp(-abs(distance + 5.7 - ringDrift) * 0.62)
            + exp(-abs(distance + 3.4 - ringDrift) * 0.62)
            + exp(-abs(distance + 1.1 - ringDrift) * 0.62)
            + exp(-abs(distance - 1.2 - ringDrift) * 0.62)
            + exp(-abs(distance - 3.5 - ringDrift) * 0.62)
            + exp(-abs(distance - 5.8 - ringDrift) * 0.62)) * fuzzNoise * 0.07;
        rings += ringFuzz;
        ringColor += ringFuzz * mix(
            float3(0.08, 0.68, 1.0),
            float3(0.9, 0.14, 1.0),
            smoothstep(-0.75, 0.75, q.x)
        );

        float cellA = floor(turn * 72.0);
        float seedA = hash21(float2(cellA, 19.0));
        float lifeA = fract(seedA + time * (0.09 + seedA * 0.08));
        float localA = fract(turn * 72.0) - 0.5 + (lifeA - 0.5) * (seedA - 0.5);
        float sparkA = exp(-localA * localA * 210.0)
            * exp(-abs(distance - (1.3 + lifeA * 10.0)) * 1.5)
            * pow(1.0 - lifeA, 2.0);

        float cellB = floor(turn * 109.0);
        float seedB = hash21(float2(cellB, 47.0));
        float lifeB = fract(seedB + time * (0.12 + seedB * 0.06));
        float localB = fract(turn * 109.0) - 0.5 - (lifeB - 0.5) * (seedB - 0.5);
        float sparkB = exp(-localB * localB * 260.0)
            * exp(-abs(distance - (1.0 + lifeB * 11.0)) * 1.75)
            * pow(1.0 - lifeB, 2.4);
        float sparks = (sparkA + sparkB) * (0.75 + cursor * 1.8);

        float energy = core * (0.65 + flow * 0.7)
            + threadA * (0.25 + pulseA)
            + threadB * (0.2 + pulseB)
            + outer + wisps + sparks * 1.7;
        energy *= 1.0 + cursor * 2.3;

        float side = smoothstep(-0.75, 0.75, q.x);
        float3 color = mix(float3(0.16, 0.72, 1.0), float3(0.82, 0.25, 1.0), side);
        color = mix(color, 1.0, saturate(core * 0.72 + pulseA + sparks + cursor));

        float edgeFade = 1.0 - smoothstep(11.5, 13.8, distance);
        energy *= edgeFade;
        rings *= edgeFade;
        ringColor *= edgeFade;
        float glow = exp(-abs(distance) * 0.22) * 0.22 * edgeFade;
        float bottomFlare = exp(-abs(distance) * 0.3)
            * exp(-q.x * q.x * 5.0) * smoothstep(-0.2, -0.9, q.y) * 0.18;
        bottomFlare *= edgeFade;
        float alpha = saturate(energy * 0.92 + rings * 0.9 + glow + bottomFlare);
        if (alpha < 0.008) discard_fragment();
        return float4(color * (energy * 1.35 + glow + bottomFlare) + ringColor * 1.2, alpha);
    }
    """#
}

private final class LauncherSessionDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class LauncherViewController: NSViewController, NSTextFieldDelegate {
    static let dismissalDuration: CFTimeInterval = 0.3
    private static let dismissalAnimationKey = "portal-singularity"

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
    private(set) var sessionHeight: CGFloat?

    private let input = NSTextField()
    private let sessionScroll = NSScrollView()
    private let sessionDocument = LauncherSessionDocument()
    private let sessionStack = NSStackView()
    private let completionEngine = PortalCompletionEngine()
    private let completionQueue = DispatchQueue(label: "dev.mxcl.portal.launcher-completion", qos: .userInitiated)
    private let sessionModel = SessionPickerModel()
    private var rows: [Row] = []
    private var sessionButtons: [NSControl] = []
    private var resultButtons: [SessionCandidateButton] = []
    private var selectedResultRow: Int?
    private var sessionRowStarts: [Int] = []
    private var sessionCandidates: [SessionRef: SessionPickerCandidate] = [:]
    private var renderedSnapshot: SessionPickerSnapshot?
    private var selectedSessionRef: SessionRef?
    private var sessionMouseDownMonitor: Any?
    private var completionSerial = 0

    static func keyboardSelectionSelfTest() -> Bool {
        let rows = [0, 3, 5, 8, 11]
        return PortalTendrilView.rendererSelfTest()
            && dismissalAnimationSelfTest()
            && remoteAddButtonSelfTest()
            && escapeSelfTest()
            && completionResizeSelfTest()
            && resultCardSelfTest()
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

    private static func remoteAddButtonSelfTest() -> Bool {
        let now = Date()
        let mac = RemoteMac(
            id: "remote",
            name: "Remote",
            online: true,
            lastSeen: now,
            homeDirectory: "~",
            sessions: []
        )
        let candidates = relayCandidates(from: [mac], localMacID: "local", now: now)
        guard candidates == relayCandidates(from: [mac], localMacID: "local", now: now),
              let candidate = candidates.first(where: { $0.action == .createRelay })
        else { return false }
        var existing = candidate
        existing.sessionRef.sessionID = "existing"
        existing.action = .attach
        let controller = LauncherViewController()
        controller.renderSessions(SessionPickerSnapshot(sections: [
            SessionPickerSection(
                location: candidate.sessionRef.location,
                title: candidate.hostTitle,
                newSession: candidate,
                items: [SessionPickerItem(
                    candidate: existing,
                    title: "~/project",
                    subtitle: nil,
                    metadata: "1 command"
                )]
            )
        ]))
        var opened: SessionPickerCandidate?
        controller.onOpenSession = { opened = $0 }
        controller.moveSessionSelection(columns: -sessionColumnCount)
        controller.moveSessionSelection(columns: -sessionColumnCount)
        controller.activateSelectionOrInput()
        let openedRemoteSession = opened?.sessionRef.location == candidate.sessionRef.location
            && opened?.sessionRef.sessionID != candidate.sessionRef.sessionID
            && opened?.action == .createRelay
        controller.moveSessionSelection(columns: sessionColumnCount)
        controller.moveSessionSelection(columns: sessionColumnCount)
        return openedRemoteSession && controller.selectedSessionRef == nil
            && controller.sessionButtons.allSatisfy {
                ($0 as? SessionCandidateButton)?.isKeyboardSelected != true
                    && ($0 as? SessionHeaderAddButton)?.isKeyboardSelected != true
            }
    }

    private static func escapeSelfTest() -> Bool {
        let controller = LauncherViewController()
        controller.input.stringValue = "query"
        var canceled = false
        controller.onCancel = { canceled = true }
        let handled = controller.control(
            controller.input,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )
        let reset = handled && controller.input.stringValue.isEmpty && !canceled
            && !controller.sessionScroll.isHidden
        _ = controller.control(
            controller.input,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )
        controller.suspend()
        return reset && canceled
    }

    private static func completionResizeSelfTest() -> Bool {
        let controller = LauncherViewController()
        var resizeCount = 0
        controller.onHeightChanged = { _ in resizeCount += 1 }
        controller.reloadRows()
        return resizeCount == 0
    }

    private static func resultCardSelfTest() -> Bool {
        let controller = LauncherViewController()
        controller.rows = (0..<4).map { .message("result \($0)") }
        controller.reloadRows()
        return controller.resultButtons.count == 4
            && controller.sessionStack.arrangedSubviews.count == 2
            && controller.sessionStack.arrangedSubviews.allSatisfy { $0 is SessionCandidateRowView }
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
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
                  let button = (self.resultButtons.isEmpty
                      ? self.sessionButtons.compactMap { $0 as? SessionCandidateButton }
                      : self.resultButtons).first(where: {
                      $0.bounds.contains($0.convert(event.locationInWindow, from: nil))
                  })
            else { return event }
            if self.resultButtons.contains(where: { $0 === button }) {
                self.openResultCard(button)
            } else {
                self.openSessionCard(button)
            }
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
        selectedResultRow = nil
        sessionButtons.forEach { setKeyboardSelected(false, on: $0) }
        input.stringValue = ""
        refreshSessions()
        view.window?.makeFirstResponder(input)
    }

    func suspend() {
        completionSerial += 1
        sessionModel.invalidate()
    }

    func animateDismissal(completion: @escaping () -> Void) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = view.layer
        else {
            completion()
            return
        }
        Self.centerAnimationAnchor(of: layer)

        let radialWarp = CIFilter.bumpDistortion()
        radialWarp.name = "singularity"
        radialWarp.center = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        radialWarp.radius = Float(hypot(layer.bounds.width, layer.bounds.height))
        radialWarp.scale = 0

        let radialStreaks = CIFilter.zoomBlur()
        radialStreaks.name = "eventHorizon"
        radialStreaks.center = radialWarp.center
        radialStreaks.amount = 0

        let warpWake = CIFilter.motionBlur()
        warpWake.name = "warpWake"
        warpWake.radius = 0
        warpWake.angle = 0

        let verticalWake = CIFilter.motionBlur()
        verticalWake.name = "verticalWake"
        verticalWake.radius = 0
        verticalWake.angle = .pi / 2
        view.contentFilters = [radialWarp, radialStreaks, warpWake, verticalWake]

        let transform = CAKeyframeAnimation(keyPath: "transform")
        transform.values = Self.dismissalTransforms.map { NSValue(caTransform3D: $0) }
        transform.keyTimes = [0, 0.32, 0.78, 1]
        transform.timingFunctions = Array(
            repeating: CAMediaTimingFunction(name: .easeIn),
            count: Self.dismissalTransforms.count - 1
        )

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [1, 1, 0.86, 0]
        opacity.keyTimes = transform.keyTimes

        let warp = CAKeyframeAnimation(keyPath: "filters.singularity.inputScale")
        warp.values = [0, -0.12, -0.72, -1]
        warp.keyTimes = transform.keyTimes

        let streaks = CAKeyframeAnimation(keyPath: "filters.eventHorizon.inputAmount")
        streaks.values = [0, 12, 48, 84]
        streaks.keyTimes = transform.keyTimes

        let wake = CAKeyframeAnimation(keyPath: "filters.warpWake.inputRadius")
        wake.values = [0, 4, 24, 52]
        wake.keyTimes = transform.keyTimes

        let verticalWakeAnimation = CAKeyframeAnimation(keyPath: "filters.verticalWake.inputRadius")
        verticalWakeAnimation.values = [0, 2, 12, 30]
        verticalWakeAnimation.keyTimes = transform.keyTimes

        let collapse = CAAnimationGroup()
        collapse.animations = [transform, opacity, warp, streaks, wake, verticalWakeAnimation]
        collapse.duration = Self.dismissalDuration
        collapse.fillMode = .forwards
        collapse.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        layer.add(collapse, forKey: Self.dismissalAnimationKey)
        CATransaction.commit()
    }

    func cancelDismissalAnimation() {
        view.layer?.removeAnimation(forKey: Self.dismissalAnimationKey)
        view.contentFilters = []
    }

    private static let dismissalTransforms = [
        CATransform3DMakeScale(1, 1, 1),
        CATransform3DMakeScale(1.04, 0.96, 1),
        CATransform3DMakeScale(1.18, 0.42, 1),
        CATransform3DMakeScale(0.006, 0.006, 1),
    ]

    private static func centerAnimationAnchor(of layer: CALayer) {
        let frame = layer.frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        CATransaction.commit()
    }

    private static func dismissalAnimationSelfTest() -> Bool {
        let layer = CALayer()
        layer.anchorPoint = .zero
        layer.frame = CGRect(x: 12, y: 18, width: 720, height: 420)
        let frame = layer.frame
        centerAnimationAnchor(of: layer)
        guard dismissalDuration == 0.3,
              dismissalTransforms.count == 4,
              let final = dismissalTransforms.last
        else { return false }
        return layer.anchorPoint == CGPoint(x: 0.5, y: 0.5)
            && layer.frame == frame
            && dismissalTransforms.allSatisfy { $0.m12 == 0 && $0.m21 == 0 }
            && abs(final.m11) < 0.01
            && abs(final.m22) < 0.01
    }

    func showError(_ message: String) {
        rows = [.message(message)]
        reloadRows()
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
            if input.stringValue.isEmpty { onCancel?() } else { reset() }
        default:
            return false
        }
        NSCursor.setHiddenUntilMouseMoves(false)
        return true
    }


    private func refreshSessions() {
        sessionScroll.isHidden = false
        if let renderedSnapshot { renderSessions(renderedSnapshot) }
        let hostname = Host.current().localizedName ?? "This Mac"
        sessionModel.refresh(
            initial: renderedSnapshot?.sections.flatMap {
                $0.items.map(\.candidate) + [$0.newSession].compactMap { $0 }
            } ?? [],
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
            (section.items.map(\.candidate) + [section.newSession].compactMap { $0 })
                .map { ($0.sessionRef, $0) }
        })
        sessionButtons.removeAll()
        resultButtons.removeAll()
        sessionRowStarts.removeAll()
        clearCards()

        for section in snapshot.sections {
            let header = NSTextField(labelWithString: section.title.uppercased())
            header.font = .systemFont(ofSize: 10, weight: .semibold)
            header.textColor = .secondaryLabelColor
            let headerStack = NSStackView(views: [header])
            headerStack.orientation = .horizontal
            headerStack.alignment = .centerY
            headerStack.spacing = 4
            if let candidate = section.newSession {
                let button = SessionHeaderAddButton(
                    sessionRef: candidate.sessionRef,
                    hostName: section.title
                )
                button.target = self
                button.action = #selector(openNewSession(_:))
                button.isKeyboardSelected = candidate.sessionRef == selectedSessionRef
                headerStack.addArrangedSubview(button)
                sessionRowStarts.append(sessionButtons.count)
                sessionButtons.append(button)
            }
            sessionStack.addArrangedSubview(headerStack)

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
        let height = 57 + sessionStack.fittingSize.height
        sessionHeight = snapshot.sections.isEmpty ? nil : height
        onHeightChanged?(height)
    }

    @objc private func openSessionCard(_ sender: SessionCandidateButton) {
        guard let candidate = sessionCandidates[sender.sessionRef] else { return }
        selectedSessionRef = sender.sessionRef
        onOpenSession?(candidate)
    }

    @objc private func openNewSession(_ sender: SessionHeaderAddButton) {
        guard var candidate = sessionCandidates[sender.sessionRef] else { return }
        candidate.sessionRef.sessionID = UUID().uuidString
        onOpenSession?(candidate)
    }

    private func refreshCompletions(_ query: String) {
        sessionScroll.isHidden = false
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
        if selectsFirst, let row = rows.firstIndex(where: \.isSelectable) {
            selectedResultRow = row
        } else if selectedResultRow.map({ rows.indices.contains($0) && rows[$0].isSelectable }) != true {
            selectedResultRow = nil
        }

        clearCards()
        resultButtons = rows.indices.map { index in
            let button: SessionCandidateButton
            switch rows[index] {
            case .session(let item):
                button = SessionCandidateButton(
                    sessionRef: item.candidate.sessionRef,
                    title: item.title,
                    subtitle: item.subtitle,
                    metadata: item.metadata
                )
            case .completion(let suggestion):
                button = SessionCandidateButton(
                    sessionRef: .local("launcher-result-\(index)"),
                    title: suggestion.displayText,
                    subtitle: nil,
                    metadata: suggestion.description ?? suggestion.source,
                    icon: suggestion.kind == .application
                        ? NSWorkspace.shared.icon(forFile: suggestion.source)
                        : nil
                )
            case .message(let message):
                button = SessionCandidateButton(
                    sessionRef: .local("launcher-result-\(index)"),
                    title: message,
                    subtitle: nil,
                    metadata: ""
                )
            }
            button.tag = index
            button.target = self
            button.action = #selector(openResultCard(_:))
            button.isEnabled = rows[index].isSelectable
            button.isKeyboardSelected = index == selectedResultRow
            return button
        }
        for start in stride(from: 0, to: resultButtons.count, by: Self.sessionColumnCount) {
            let buttons = Array(resultButtons[start..<min(start + Self.sessionColumnCount, resultButtons.count)])
            let row = SessionCandidateRowView(buttons: buttons, columnCount: Self.sessionColumnCount)
            sessionStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: sessionStack.widthAnchor).isActive = true
        }
    }

    private func moveSelection(_ offset: Int) {
        let selectable = rows.indices.filter { rows[$0].isSelectable }
        guard !selectable.isEmpty else { return }
        let index = selectedResultRow.flatMap { selectable.firstIndex(of: $0) } ?? (offset > 0 ? -1 : 0)
        let next = (index + offset + selectable.count) % selectable.count
        selectedResultRow = selectable[next]
        resultButtons.forEach { $0.isKeyboardSelected = $0.tag == selectedResultRow }
        if let button = resultButtons.first(where: { $0.tag == selectedResultRow }) {
            button.scrollToVisible(button.bounds)
        }
    }

    @objc private func openResultCard(_ sender: SessionCandidateButton) {
        guard rows.indices.contains(sender.tag), rows[sender.tag].isSelectable else { return }
        selectedResultRow = sender.tag
        activateSelectionOrInput()
    }

    private func clearCards() {
        for view in sessionStack.arrangedSubviews {
            sessionStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func moveSessionSelection(columns delta: Int) {
        guard !sessionButtons.isEmpty else { return }
        let current = selectedSessionRef.flatMap { selected in
            sessionButtons.firstIndex { sessionRef(for: $0) == selected }
        }
        guard let destination = Self.sessionSelectionDestination(
            current: current,
            delta: delta,
            rowStarts: sessionRowStarts,
            count: sessionButtons.count
        ) else {
            if delta == Self.sessionColumnCount {
                selectedSessionRef = nil
                sessionButtons.forEach { setKeyboardSelected(false, on: $0) }
            }
            return
        }
        sessionButtons.forEach { setKeyboardSelected(false, on: $0) }
        let button = sessionButtons[destination]
        setKeyboardSelected(true, on: button)
        selectedSessionRef = sessionRef(for: button)
        button.scrollToVisible(button.bounds)
    }

    private func sessionRef(for button: NSControl) -> SessionRef? {
        (button as? SessionCandidateButton)?.sessionRef
            ?? (button as? SessionHeaderAddButton)?.sessionRef
    }

    private func setKeyboardSelected(_ selected: Bool, on button: NSControl) {
        (button as? SessionCandidateButton)?.isKeyboardSelected = selected
        (button as? SessionHeaderAddButton)?.isKeyboardSelected = selected
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
        guard let selectedResultRow, rows.indices.contains(selectedResultRow),
              case .completion(let suggestion) = rows[selectedResultRow]
        else { return }
        input.stringValue = suggestion.insertText
        refreshCompletions(input.stringValue)
    }

    private func activateSelectionOrInput() {
        if input.stringValue.isEmpty,
           let selectedSessionRef,
           let button = sessionButtons.first(where: { sessionRef(for: $0) == selectedSessionRef }) {
            button.performClick(nil)
            return
        }
        if !input.stringValue.isEmpty,
           let selectedResultRow,
           rows.indices.contains(selectedResultRow) {
            switch rows[selectedResultRow] {
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
        return relayCandidates(from: catalog.macs, localMacID: localMacID, now: now)
    }

    private static func relayCandidates(
        from macs: [RemoteMac],
        localMacID: String,
        now: Date
    ) -> [SessionPickerCandidate] {
        macs
            .filter { $0.id != localMacID && $0.online && now.timeIntervalSince($0.lastSeen) < 10 }
            .flatMap { mac in
                let location = SessionLocation.relayMac(mac.id)
                let newSession = SessionPickerCandidate(
                    sessionRef: SessionRef(
                        location: location,
                        sessionID: "new-session",
                        hostName: mac.name
                    ),
                    hostTitle: mac.name,
                    title: "New session",
                    cwd: mac.homeDirectory ?? "/",
                    isClosed: false,
                    createdAt: nil,
                    commandCount: 0,
                    commandHistory: [],
                    action: .createRelay
                )
                return [newSession] + mac.sessions.map { session in
                    SessionPickerCandidate(
                        sessionRef: SessionRef(
                            location: location,
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

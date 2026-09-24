import AppKit

/// Keep trackpad gestures on one axis, including their momentum phase.
final class EditorScrollView: NSScrollView {
    private var horizontalGesture: Bool?

    func axisLockedEvent(_ event: NSEvent) -> NSEvent {
        guard !event.phase.isEmpty || !event.momentumPhase.isEmpty else {
            horizontalGesture = nil
            return event
        }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            horizontalGesture = nil
        }
        defer {
            if event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) {
                horizontalGesture = nil
            }
        }
        if horizontalGesture == nil, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            horizontalGesture = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        }
        // Keep the axis after finger-up: momentum arrives as a separate event sequence.
        guard let horizontalGesture, let copy = event.cgEvent?.copy() else { return event }
        let suppressedFields: [CGEventField] = horizontalGesture
            ? [.scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1]
            : [.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2]
        for field in suppressedFields {
            copy.setDoubleValueField(field, value: 0)
        }
        return NSEvent(cgEvent: copy) ?? event
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: axisLockedEvent(event))
    }
}

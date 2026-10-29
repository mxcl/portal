import Testing

// AppKit focus and UserDefaults are process-wide, even across MainActor suspensions.
@Suite(.serialized)
struct PortalAppTestSuite {}

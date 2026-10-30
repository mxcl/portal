import Foundation

struct MobileUnlockPolicy {
    private let defaults: UserDefaults
    private static let preferenceKey = "portalRequiresBiometricUnlock"

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.preferenceKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.preferenceKey) as? Bool ?? true
    }

    func shouldLock(backgroundedAt: Date?, now: Date = .now) -> Bool {
        isEnabled && backgroundedAt.map { now.timeIntervalSince($0) >= 300 } == true
    }

    func needsAuthentication(
        force: Bool, lastAuthenticatedAt: Date?, isLocked: Bool, now: Date = .now
    ) -> Bool {
        guard isEnabled else { return false }
        if !force, !isLocked, let lastAuthenticatedAt,
           now.timeIntervalSince(lastAuthenticatedAt) < 300 { return false }
        return true
    }
}

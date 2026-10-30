import Foundation
import Testing
@testable import PortalMobile

@Test func unlockPreferenceDefaultsOnAndPersists() throws {
    let suite = "MobileUnlockPolicyTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var policy = MobileUnlockPolicy(defaults: defaults)
    #expect(policy.isEnabled)
    policy.isEnabled = false
    #expect(!MobileUnlockPolicy(defaults: defaults).isEnabled)
    let now = Date()
    #expect(!policy.shouldLock(backgroundedAt: now.addingTimeInterval(-301), now: now))
    #expect(!policy.needsAuthentication(force: true, lastAuthenticatedAt: nil, isLocked: true, now: now))
    policy.isEnabled = true
    #expect(MobileUnlockPolicy(defaults: defaults).isEnabled)
    #expect(policy.shouldLock(backgroundedAt: now.addingTimeInterval(-300), now: now))
    #expect(!policy.shouldLock(backgroundedAt: now.addingTimeInterval(-299), now: now))
    #expect(!policy.shouldLock(backgroundedAt: nil, now: now))
    #expect(policy.needsAuthentication(force: false, lastAuthenticatedAt: nil, isLocked: false, now: now))
    #expect(!policy.needsAuthentication(force: false, lastAuthenticatedAt: now, isLocked: false, now: now))
    #expect(policy.needsAuthentication(force: true, lastAuthenticatedAt: now, isLocked: false, now: now))
    #expect(policy.needsAuthentication(force: false, lastAuthenticatedAt: now, isLocked: true, now: now))
    #expect(policy.needsAuthentication(force: false, lastAuthenticatedAt: now.addingTimeInterval(-300), isLocked: false, now: now))
}

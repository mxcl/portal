import Foundation
import Testing
@testable import PortalCore

@Test func activeICloudAccountRequiresAnIdentityToken() {
    #expect(!ICloudKeychainRootKey.hasActiveICloudAccount(identityToken: nil))
    #expect(ICloudKeychainRootKey.hasActiveICloudAccount(identityToken: NSObject()))
}

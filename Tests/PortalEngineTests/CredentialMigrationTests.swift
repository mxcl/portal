#if os(macOS)
import Foundation
import Security
import Testing
@testable import PortalEngine

@Test @MainActor func credentialServiceRenamesInPlace() throws {
    let credential = Data("fixture".utf8)
    var reads = 0
    let result = try GitHubController.readCredential(copy: { query, value in
        #expect((query as NSDictionary)[kSecAttrService] as? String == "dev.mxcl.portal.github")
        reads += 1
        if reads == 1 { return errSecItemNotFound }
        value?.pointee = credential as CFData
        return errSecSuccess
    }, update: { query, attributes in
        #expect((query as NSDictionary)[kSecAttrService] as? String == "dev.mxcl.git-sync.github")
        #expect((attributes as NSDictionary)[kSecAttrService] as? String == "dev.mxcl.portal.github")
        #expect((attributes as NSDictionary)[kSecValueData] == nil)
        return errSecSuccess
    })
    #expect(result == credential)
    #expect(reads == 2)
}

@Test @MainActor func existingPortalCredentialWins() throws {
    let result = try GitHubController.readCredential(copy: { _, value in
        value?.pointee = Data("current".utf8) as CFData
        return errSecSuccess
    }, update: { _, _ in Issue.record("Must not modify an existing Portal credential"); return errSecParam })
    #expect(result == Data("current".utf8))
}

@Test @MainActor func deniedCredentialMigrationDoesNotDiscardCredential() {
    #expect(throws: (any Error).self) {
        try GitHubController.readCredential(copy: { _, _ in errSecItemNotFound },
            update: { _, _ in errSecAuthFailed })
    }
}
#endif

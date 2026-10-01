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
    }, repairAccess: {})
    #expect(result == credential)
    #expect(reads == 2)
}

@Test @MainActor func existingPortalCredentialWins() throws {
    let result = try GitHubController.readCredential(copy: { _, value in
        value?.pointee = Data("current".utf8) as CFData
        return errSecSuccess
    }, update: { _, _ in Issue.record("Must not modify an existing Portal credential"); return errSecParam }, repairAccess: {})
    #expect(result == Data("current".utf8))
}

@Test @MainActor func deniedCredentialMigrationDoesNotDiscardCredential() {
    #expect(throws: (any Error).self) {
        try GitHubController.readCredential(copy: { _, _ in errSecItemNotFound },
            update: { _, _ in errSecAuthFailed }, repairAccess: {})
    }
}
@Test @MainActor func legacyCredentialAccessMigratesOnce() throws {
    var application: SecTrustedApplication?
    #expect(SecTrustedApplicationCreateFromPath(nil, &application) == errSecSuccess)
    var access: SecAccess?
    #expect(SecAccessCreate("dev.mxcl.git-sync.github" as CFString,
                          [try #require(application)] as CFArray, &access) == errSecSuccess)
    let value = try #require(access)
    #expect(try GitHubController.migrateCredentialAccess(value))
    #expect(try !GitHubController.migrateCredentialAccess(value))
    var list: CFArray?
    #expect(SecAccessCopyACLList(value, &list) == errSecSuccess)
    for acl in try #require(list as? [SecACL]) {
        var applications: CFArray?
        var description: CFString?
        var selector = SecKeychainPromptSelector()
        #expect(SecACLCopyContents(acl, &applications, &description, &selector) == errSecSuccess)
        #expect(description as String? == "Portal GitHub")
        if let trusted = applications as? [SecTrustedApplication], !trusted.isEmpty {
            #expect(trusted.count == 2) // Retains existing trust and adds the current signed helper.
        }
    }
}
#endif

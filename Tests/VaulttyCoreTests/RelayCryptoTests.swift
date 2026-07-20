import CryptoKit
import Foundation
import Testing
@testable import VaulttyCore

@Suite("Relay cryptography")
struct RelayCryptoTests {
    private let rootKey = Data((0..<RelayCrypto.rootKeyByteCount).map(UInt8.init))

    @Test("address derivation is stable and separates room from credential")
    func addressDerivation() throws {
        let first = try RelayCrypto(rootKeyData: rootKey).address
        let second = try RelayCrypto(rootKeyData: rootKey).address

        #expect(first == second)
        #expect(first.room != first.credential)
        #expect(!first.room.contains("+"))
        #expect(!first.room.contains("/"))
    }

    @Test("ciphertext round trips only for the intended purpose")
    func roundTrip() throws {
        let crypto = try RelayCrypto(rootKeyData: rootKey)
        let plaintext = Data("secret terminal bytes".utf8)
        let envelope = try crypto.seal(plaintext, purpose: "session")

        #expect(try crypto.open(envelope, purpose: "session") == plaintext)
        #expect(throws: (any Error).self) {
            try crypto.open(envelope, purpose: "catalog")
        }
    }

    @Test("tampering fails authentication")
    func rejectsTampering() throws {
        let crypto = try RelayCrypto(rootKeyData: rootKey)
        let envelope = try crypto.seal(Data("input".utf8), purpose: "session")
        var tampered = envelope.combined
        tampered[tampered.startIndex] ^= 1

        #expect(throws: (any Error).self) {
            try crypto.open(RelayCiphertext(combined: tampered), purpose: "session")
        }
    }

    @Test("root key length is enforced")
    func keyLength() {
        #expect(throws: RelayCryptoError.invalidRootKey) {
            try RelayCrypto(rootKeyData: Data(repeating: 0, count: 31))
        }
    }
}

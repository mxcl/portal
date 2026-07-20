import CryptoKit
import Foundation

enum RelayCryptoError: Error, Equatable {
    case invalidRootKey
    case invalidEnvelope
    case unsupportedVersion
}

struct RelayAddress: Equatable, Sendable {
    let room: String
    let credential: String
}

struct RelayCiphertext: Codable, Equatable, Sendable {
    static let currentVersion: UInt16 = 1

    let version: UInt16
    let combined: Data

    init(version: UInt16 = currentVersion, combined: Data) {
        self.version = version
        self.combined = combined
    }
}

struct RelayCrypto: Sendable {
    static let rootKeyByteCount = 32

    private let rootKey: SymmetricKey

    init(rootKeyData: Data) throws {
        guard rootKeyData.count == Self.rootKeyByteCount else {
            throw RelayCryptoError.invalidRootKey
        }
        rootKey = SymmetricKey(data: rootKeyData)
    }

    var address: RelayAddress {
        RelayAddress(
            room: identifier(label: "room"),
            credential: identifier(label: "credential")
        )
    }

    func seal(_ plaintext: Data, purpose: String) throws -> RelayCiphertext {
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key(purpose: purpose),
            authenticating: authenticatedData(purpose: purpose)
        )
        guard let combined = sealed.combined else {
            throw RelayCryptoError.invalidEnvelope
        }
        return RelayCiphertext(combined: combined)
    }

    func open(_ envelope: RelayCiphertext, purpose: String) throws -> Data {
        guard envelope.version == RelayCiphertext.currentVersion else {
            throw RelayCryptoError.unsupportedVersion
        }
        let box = try AES.GCM.SealedBox(combined: envelope.combined)
        return try AES.GCM.open(
            box,
            using: key(purpose: purpose),
            authenticating: authenticatedData(purpose: purpose)
        )
    }

    private func key(purpose: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: rootKey,
            salt: Data("vaultty-relay-v1".utf8),
            info: Data(purpose.utf8),
            outputByteCount: Self.rootKeyByteCount
        )
    }

    private func authenticatedData(purpose: String) -> Data {
        Data("vaultty:\(RelayCiphertext.currentVersion):\(purpose)".utf8)
    }

    private func identifier(label: String) -> String {
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: Data("vaultty-relay-address:\(label):v1".utf8),
            using: rootKey
        )
        return Data(authenticationCode)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}


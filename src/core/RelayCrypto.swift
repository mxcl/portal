import CryptoKit
import Foundation

public enum RelayCryptoError: Error, Equatable {
    case invalidRootKey
    case invalidEnvelope
    case unsupportedVersion
}

public struct RelayAddress: Equatable, Sendable {
    public let room: String
    public let credential: String
}

public struct RelayCiphertext: Codable, Equatable, Sendable {
    public static let currentVersion: UInt16 = 1

    public let version: UInt16
    public let combined: Data

    public init(version: UInt16 = currentVersion, combined: Data) {
        self.version = version
        self.combined = combined
    }
}

public struct RelayCrypto: Sendable {
    public static let rootKeyByteCount = 32

    private let rootKey: SymmetricKey

    public init(rootKeyData: Data) throws {
        guard rootKeyData.count == Self.rootKeyByteCount else {
            throw RelayCryptoError.invalidRootKey
        }
        rootKey = SymmetricKey(data: rootKeyData)
    }

    public var address: RelayAddress {
        RelayAddress(
            room: identifier(label: "room"),
            credential: identifier(label: "credential")
        )
    }

    public func seal(_ plaintext: Data, purpose: String) throws -> RelayCiphertext {
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

    public func open(_ envelope: RelayCiphertext, purpose: String) throws -> Data {
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

import Foundation
import CryptoKit
import Security
import Darwin

public struct DiscoveryHost: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID().uuidString
    public var name = ""
    public var address = ""
    public var username = ""
    public var port = 22
    public var hostPublicKey = ""
    public var helperPath = "/Applications/Portal Hub.app/Contents/Helpers/portal-session-bridge"
    public var homeDirectory = ""
    public var shellPath = "/bin/zsh"
    public init() {}

    public static func isPrivateAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, value, &ipv4) == 1 {
            let n = UInt32(bigEndian: ipv4.s_addr)
            return n >> 24 == 10 || n >> 20 == 0xac1 || n >> 16 == 0xc0a8 || n >> 22 == 0x191
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, value, &ipv6) == 1 else { return false }
        return withUnsafeBytes(of: ipv6) { ($0[0] & 0xfe) == 0xfc }
    }
}

public struct HostRegistration: Codable, Identifiable, Equatable, Sendable {
    public var id: String { host.id }
    public let version: Int
    public let owner: String
    public let identity: String
    public var host: DiscoveryHost
    public init(host: DiscoveryHost, owner: String, token: Data) {
        version = 1; self.host = host; self.owner = owner
        identity = PortalIdentity.fingerprint(token)
    }
}

public enum PortalIdentity {
    public static func fingerprint(_ token: Data) -> String {
        SHA256.hash(data: token).map { String(format: "%02x", $0) }.joined()
    }
    public static func publicKey(token: Data) throws -> String {
        let seed = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: token),
            info: Data("dev.mxcl.portal.ssh.v1".utf8), outputByteCount: 32)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed.withUnsafeBytes { Data($0) })
        var blob = Data()
        for field in [Data("ssh-ed25519".utf8), key.publicKey.rawRepresentation] {
            var count = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &count) { blob.append(contentsOf: $0) }
            blob.append(field)
        }
        return "ssh-ed25519 \(blob.base64EncodedString()) portal-iphone"
    }
}

/// Each Mac owns its record and any Linux records it explicitly enrolls. Readers never write them.
public struct HostDirectory {
    public init() {}
    private var query: [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.mxcl.portal.hosts.v1", kSecAttrSynchronizable as String: true]
        #if os(macOS)
        result[kSecUseDataProtectionKeychain as String] = true
        #endif
        return result
    }
    public func registrations() throws -> [HostRegistration] {
        var query = query
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw ICloudKeychainError.unavailable(status) }
        guard let values = result as? [Data] else { throw ICloudKeychainError.invalidKey }
        return try Self.decode(values)
    }
    static func decode(_ values: [Data]) throws -> [HostRegistration] {
        return try values.map {
            let record = try JSONDecoder().decode(HostRegistration.self, from: $0)
            guard record.version == 1 else { throw DirectoryError("Update Portal to read this host directory.") }
            return record
        }.sorted { $0.host.name.localizedStandardCompare($1.host.name) == .orderedAscending }
    }
    public func hosts(token: Data) throws -> [DiscoveryHost] {
        Self.select(try registrations(), token: token)
    }
    static func select(_ records: [HostRegistration], token: Data) -> [DiscoveryHost] {
        let fingerprint = PortalIdentity.fingerprint(token)
        return records.filter { $0.identity == fingerprint }.map(\.host)
    }
    public func publish(_ record: HostRegistration) throws {
        let existing = try registrations().first { $0.id == record.id }
        if let existing, existing.owner != record.owner {
            throw DirectoryError("This host is managed by another Mac. Disable it there before enrolling it here.")
        }
        if existing == record { return }
        var query = query
        query[kSecAttrAccount as String] = record.id
        let value = try JSONEncoder().encode(record)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = value
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ICloudKeychainError.unavailable(status) }
    }
    public func remove(id: String, owner: String) throws {
        guard let record = try registrations().first(where: { $0.id == id }) else { return }
        guard record.owner == owner else { throw DirectoryError("Disable this host on the Mac that enrolled it.") }
        var query = query; query[kSecAttrAccount as String] = id
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ICloudKeychainError.unavailable(status) }
    }
}

public struct DirectoryError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

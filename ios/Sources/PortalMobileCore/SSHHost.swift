import Foundation
import Darwin
import Crypto
import Citadel
import NIOSSH

public enum SSHSessionError: Error, LocalizedError {
    case configuration(String)
    case disconnected
    case incompatibleProtocol
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .configuration(let message): return message
        case .disconnected: return "SSH disconnected. Connect your VPN and try again."
        case .incompatibleProtocol: return "Update Portal on this Mac before connecting."
        case .invalidResponse: return "The SSH session helper returned an invalid response."
        }
    }
}

public struct SSHHost: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID().uuidString
    public var name = ""
    public var address = ""
    public var username = ""
    public var port = 22
    public var hostPublicKey = ""
    public var helperPath = "/Applications/Portal.app/Contents/Helpers/portal-session-bridge"
    public var homeDirectory = ""
    public var shellPath = "/bin/zsh"

    public init() {}

    public static func load() -> [SSHHost] {
        guard let data = UserDefaults.standard.data(forKey: "portalSSHHosts") else { return [] }
        return (try? JSONDecoder().decode([SSHHost].self, from: data)) ?? []
    }

    public func validate() throws {
        guard Self.isPrivateAddress(address) else {
            throw SSHSessionError.configuration("Enter your Mac’s private VPN IP address (for example its Tailscale 100.x address). Public addresses and DNS names are not accepted.")
        }
        guard !name.isEmpty, !username.isEmpty, (1...65535).contains(port),
              helperPath.hasPrefix("/"), homeDirectory.hasPrefix("/"), shellPath.hasPrefix("/"),
              ![username, helperPath, homeDirectory, shellPath].contains(where: { $0.contains("\0") || $0.contains("\n") }) else {
            throw SSHSessionError.configuration("Enter a name, SSH user, valid port, and absolute helper, home and shell paths.")
        }
        _ = try NIOSSHPublicKey(openSSHPublicKey: hostPublicKey)
    }

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

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    var command: String { "exec " + Self.quote(helperPath) }
}

public enum SSHIdentity {
    // Keep the existing synchronizable token. Derive a separate signing identity for SSH.
    static func privateKey(token: Data) throws -> Curve25519.Signing.PrivateKey {
        let seed = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: token),
            info: Data("dev.mxcl.portal.ssh.v1".utf8), outputByteCount: 32)
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed.withUnsafeBytes { Data($0) })
    }

    public static func publicKey() throws -> String {
        try publicKey(token: ICloudKeychainRootKey().loadOrCreate())
    }

    static func publicKey(token: Data) throws -> String {
        let key = try privateKey(token: token).publicKey.rawRepresentation
        var blob = Data()
        for field in [Data("ssh-ed25519".utf8), key] {
            var count = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &count) { blob.append(contentsOf: $0) }
            blob.append(field)
        }
        return "ssh-ed25519 \(blob.base64EncodedString()) portal-iphone"
    }
}

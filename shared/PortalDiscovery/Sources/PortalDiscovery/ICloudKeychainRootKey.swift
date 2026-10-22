import Foundation
import Security

public enum ICloudKeychainError: Error, Equatable, LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable(errSecItemNotFound): return "Waiting for Portal’s token in iCloud Keychain. Refresh after it syncs, or create an identity on your first device."
        case .unavailable(let status), .randomGenerationFailed(let status): return "iCloud Keychain is unavailable (\(status))."
        case .invalidKey: return "Portal’s Keychain token is invalid."
        }
    }
    case unavailable(OSStatus)
    case invalidKey
    case randomGenerationFailed(OSStatus)
}

public struct ICloudKeychainRootKey {
    public static let service = "dev.mxcl.portal.remote"
    public static let account = "account-root-key-v1"

    public static func hasActiveICloudAccount(
        identityToken: Any? = FileManager.default.ubiquityIdentityToken
    ) -> Bool {
        identityToken != nil
    }

    public init() {}

    public func loadOrCreate() throws -> Data {
        switch load() {
        case .success(let key):
            return key
        case .failure(.unavailable(errSecItemNotFound)):
            let key = try generate()
            let status = add(key)
            if status == errSecSuccess {
                return key
            }
            if status == errSecDuplicateItem, case .success(let winner) = load() {
                return winner
            }
            throw ICloudKeychainError.unavailable(status)
        case .failure(let error):
            throw error
        }
    }

    public func load() -> Result<Data, ICloudKeychainError> {
        var query = primaryKey
        query[kSecAttrSynchronizable as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            return .failure(.unavailable(status))
        }
        guard let key = result as? Data, key.count == 32 else {
            return .failure(.invalidKey)
        }
        return .success(key)
    }

    private func add(_ key: Data) -> OSStatus {
        var query = primaryKey
        query[kSecAttrSynchronizable as String] = true
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        query[kSecValueData as String] = key
        return SecItemAdd(query as CFDictionary, nil)
    }

    private var primaryKey: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
#if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
#endif
        return query
    }

    private func generate() throws -> Data {
        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw ICloudKeychainError.randomGenerationFailed(status)
        }
        return data
    }
}

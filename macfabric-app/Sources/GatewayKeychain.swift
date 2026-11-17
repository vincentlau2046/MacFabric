// Keychain 凭据存取（plan B2）：service=io.macfabric.gateway-api-key，account=<profile>|<origin>
// 规则：不静默建 key；不读摘要恢复；拒绝/锁定如实抛错，调用方绝不声称“已保存”。
// 调试档 fixture 测试不触真实 Keychain（契约测试用 RecordingStore）。
import Foundation
import Security

struct KeychainCredentialStore: GatewayCredentialStore {
    func load(profile: GatewayProfile) throws -> String? {
        var query = baseQuery(profile)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw CredentialStoreError.unavailable }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            throw CredentialStoreError.interactionNotAllowed
        default:
            throw CredentialStoreError.denied
        }
    }

    func save(_ key: String, profile: GatewayProfile) throws {
        // 先删旧值再写入（同 account 唯一）
        SecItemDelete(baseQuery(profile) as CFDictionary)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: GatewayProfile.keychainService,
            kSecAttrAccount as String: profile.keychainAccount,
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw status == errSecInteractionNotAllowed ? CredentialStoreError.interactionNotAllowed : CredentialStoreError.denied
        }
    }

    func delete(profile: GatewayProfile) throws {
        let status = SecItemDelete(baseQuery(profile) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.denied
        }
    }

    private func baseQuery(_ profile: GatewayProfile) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: GatewayProfile.keychainService,
            kSecAttrAccount as String: profile.keychainAccount,
        ]
    }
}

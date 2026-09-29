import Foundation
import Security

/// API Key 的存储。
///
/// 为什么必须是 Keychain 而不是 UserDefaults / 文件：
///  - 免费签名每 7 天要重装一次，App 沙盒里的文件有丢的风险，Keychain 项在覆盖安装时保留
///  - Keychain 内容不会被导出到 iTunes / 文件 App 的备份里
enum KeychainStore {

    private static let service = "com.niuyuxiaosir.iphoneassistant"

    @discardableResult
    static func save(_ value: String, for account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        // 先删再加，避免 errSecDuplicateItem
        _ = SecItemDelete(baseQuery(account: account) as CFDictionary)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load(for account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for account: String) {
        _ = SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

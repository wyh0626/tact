import Foundation
import Security

/// Secrets live in the login keychain, never in config.json. The app hands
/// the model key to the engine through its environment when it starts it.
enum Keychain {
    /// Tests point this elsewhere so they never touch the app's real entry.
    static var service = "io.github.wyh0626.tact"
    static let modelKey = "model-api-key"

    static func read(_ account: String, service: String = Keychain.service) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores `value`, or deletes the entry when it is empty.
    @discardableResult
    static func save(_ value: String, account: String, service: String = Keychain.service) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else {
            Log.info("⚠️ 写入钥匙串失败（\(update)）")
            return false
        }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { Log.info("⚠️ 写入钥匙串失败（\(status)）") }
        return status == errSecSuccess
    }
}

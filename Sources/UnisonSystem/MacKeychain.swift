import Foundation
import Security
import UnisonDomain

public final class MacKeychain: KeychainService, @unchecked Sendable {
    private static let log = UnisonLog(category: "MacKeychain")

    public let service: String
    public let account: String

    public init(service: String = "com.unison.app", account: String = "openai-api-key") {
        self.service = service
        self.account = account
    }

    public func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // The `String?` protocol shape forces every failure to read as
        // "no key stored", but a locked keychain / ACL denial is NOT
        // the same as absence — the UI would route the user back
        // through key entry and overwrite a valid key. At minimum the
        // distinction must be visible in the diagnostic log.
        if status != errSecSuccess && status != errSecItemNotFound {
            Self.log.error("loadAPIKey — SecItemCopyMatching failed with status \(status) (locked keychain / ACL denial?); treating as no key, but a key may exist")
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    public func saveAPIKey(_ key: String) throws {
        let data = key.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var addItem = query
            addItem[kSecValueData as String] = data
            let addStatus = SecItemAdd(addItem as CFDictionary, nil)
            if addStatus != errSecSuccess {
                throw NSError(domain: "Keychain", code: Int(addStatus))
            }
        } else if status != errSecSuccess {
            throw NSError(domain: "Keychain", code: Int(status))
        }
    }

    public func deleteAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw NSError(domain: "Keychain", code: Int(status))
        }
    }
}

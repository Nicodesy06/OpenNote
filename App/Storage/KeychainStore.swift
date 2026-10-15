import Foundation
import Security

/// Archivio delle chiavi API nel Keychain. Le credenziali non vengono mai
/// salvate in UserDefaults, nei file dell'app o nei log.
///
/// Accessibilità `AfterFirstUnlockThisDeviceOnly`: le chiavi servono anche
/// quando un lavoro riprende in background a schermo bloccato, e non vengono
/// migrate su altri dispositivi tramite backup.
struct KeychainStore: Sendable {
    let service: String

    init(service: String = "it.quadernoai.apikeys") {
        self.service = service
    }

    enum KeychainError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                return "Errore del Portachiavi (\(status))."
            }
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func save(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        var query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
    }

    func hasValue(account: String) -> Bool {
        read(account: account)?.isEmpty == false
    }
}

enum APIKeyAccount {
    static let openAI = "openai"
    static let anthropic = "anthropic"
    static let backendToken = "backend-token"
}

import Foundation
import Security

/// Sur iPhone : l'adresse du serveur et le jeton sont gardés dans le Trousseau,
/// accessibles seulement quand l'iPhone a été déverrouillé depuis son démarrage.
@MainActor
enum ConnectionStore {
    private static let service = "com.spoooke.egide.argos"
    private static let account = "connection"

    static let missingMessage = "Non connecté."

    static func load() -> Connection? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Connection.self, from: data)
    }

    static func save(_ c: Connection) {
        clear()
        guard let data = try? JSONEncoder().encode(c) else { return }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Jeton refusé (par exemple après « Générer un nouveau jeton » sur le Mac) : retour à la connexion.
    static func unauthorized(_ model: AppModel) {
        model.disconnect()
    }
}

import Foundation
import Security

/// Clé personnelle VirusTotal, rangée dans le trousseau du Mac (jamais dans un fichier ni dans un rapport).
public enum CleReputation {
    /// Où la clé est rangée, pour les messages.
    public static let coffre = "trousseau"

    private static var recherche: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.spoooke.cerbere.virustotal", kSecAttrAccount as String: "cle"]
    }

    /// Une clé est-elle rangée ? Sans la lire (le trousseau ne demande alors rien).
    public static var existe: Bool {
        SecItemCopyMatching(recherche.merging([kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 } as CFDictionary, nil) == errSecSuccess
    }

    public static func lire() -> String? {
        var resultat: CFTypeRef?
        let demande = recherche.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        guard SecItemCopyMatching(demande as CFDictionary, &resultat) == errSecSuccess, let donnees = resultat as? Data else { return nil }
        return String(data: donnees, encoding: .utf8)
    }

    /// Range la clé (ou la remplace). Faux si elle n'a pas la forme d'une clé ou si le trousseau refuse.
    @discardableResult
    public static func enregistrer(_ cle: String) -> Bool {
        let propre = cle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard propre.count >= 20, propre.count <= 200, propre.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
        SecItemDelete(recherche as CFDictionary)
        return SecItemAdd(recherche.merging([kSecValueData as String: Data(propre.utf8)]) { $1 } as CFDictionary, nil) == errSecSuccess
    }

    public static func effacer() { SecItemDelete(recherche as CFDictionary) }
}

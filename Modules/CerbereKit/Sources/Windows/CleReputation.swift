import Foundation
import WinSDK

/// Clé personnelle VirusTotal, rangée dans le gestionnaire d'identifiants de Windows (jamais dans un fichier ni dans
/// un rapport), pour ce compte et cette machine seulement.
public enum CleReputation {
    /// Où la clé est rangée, pour les messages.
    public static let coffre = "gestionnaire d'identifiants de Windows"
    private static let cible = "Cerbere/virustotal"

    public static var existe: Bool { lire() != nil }

    public static func lire() -> String? {
        var trouve: PCREDENTIALW?
        let ok = cible.withCString(encodedAs: UTF16.self) { CredReadW($0, DWORD(CRED_TYPE_GENERIC), 0, &trouve) }
        guard ok, let c = trouve else { return nil }
        defer { CredFree(c) }
        guard let octets = c.pointee.CredentialBlob else { return nil }
        return String(decoding: UnsafeBufferPointer(start: octets, count: Int(c.pointee.CredentialBlobSize)), as: UTF8.self)
    }

    /// Range la clé (ou la remplace). Faux si elle n'a pas la forme d'une clé ou si Windows refuse.
    @discardableResult
    public static func enregistrer(_ cle: String) -> Bool {
        let propre = cle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard propre.count >= 20, propre.count <= 200, propre.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
        var octets = Array(propre.utf8)
        return cible.withCString(encodedAs: UTF16.self) { nom in
            "cle".withCString(encodedAs: UTF16.self) { compte in
                octets.withUnsafeMutableBufferPointer { b in
                    var c = CREDENTIALW()
                    c.Type = DWORD(CRED_TYPE_GENERIC)
                    c.TargetName = UnsafeMutablePointer(mutating: nom)
                    c.UserName = UnsafeMutablePointer(mutating: compte)
                    c.CredentialBlobSize = DWORD(b.count)
                    c.CredentialBlob = b.baseAddress
                    c.Persist = DWORD(CRED_PERSIST_LOCAL_MACHINE)
                    return CredWriteW(&c, 0)
                }
            }
        }
    }

    public static func effacer() {
        _ = cible.withCString(encodedAs: UTF16.self) { CredDeleteW($0, DWORD(CRED_TYPE_GENERIC), 0) }
    }
}

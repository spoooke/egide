import Foundation

/// Sur Mac (Égide Mac) : on parle au serveur Argos installé sur cette machine, avec le jeton de son dossier
/// de données. Rien à saisir ni à enregistrer. Repris d'Argos/argos/apple/macOS.
@MainActor
enum ConnectionStore {
    nonisolated static let serverURL = URL(string: "http://127.0.0.1:8787")!
    static let tokenURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Heartbit/data/token")

    static let missingMessage = "Serveur Argos introuvable sur ce Mac : lance scripts/install-mac.sh dans le dépôt Argos."

    static func readToken() -> String? {
        (try? String(contentsOf: tokenURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func load() -> Connection? {
        readToken().map { Connection(baseURL: serverURL, token: $0) }
    }

    static func save(_ c: Connection) {}
    static func clear() {}

    /// Jeton changé entre-temps : on le relira au prochain rafraîchissement.
    static func unauthorized(_ model: AppModel) {
        model.connection = nil
    }
}

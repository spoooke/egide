import Foundation

// Services d'Hermès pour l'app : résumé de l'Accueil, sauvegarde globale.
extension HermesKit {
    /// « Spooke · il y a 2 h » : dernier Mac utilisé (nil si aucun Mac appairé).
    @MainActor
    public static func summary() async -> String? {
        let macs = MacStore().macs
        guard let last = macs.max(by: { ($0.lastConnected ?? .distantPast) < ($1.lastConnected ?? .distantPast) }) else { return nil }
        guard let date = last.lastConnected else { return last.name }
        return "\(last.name) · \(date.formatted(.relative(presentation: .named)))"
    }

    /// Rien à sauvegarder : la clé de l'iPhone ne quitte jamais la Secure Enclave, un nouvel appairage est nécessaire.
    @MainActor
    public static func backup() throws -> Data? { nil }

    @MainActor
    public static func restore(_ data: Data) throws -> String { "rien à restaurer" }
}

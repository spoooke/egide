import Foundation

// Services d'Argos pour l'app : résumé de l'Accueil, sauvegarde globale.
extension ArgosKit {
    /// « Score 87 · 2 à corriger » : moyenne des appareils, lue sur le serveur (nil si non connecté ou injoignable).
    @MainActor
    public static func summary() async -> String? {
        if DemoArgos.actif { return "Score 91 · 1 à corriger" }
        guard let connection = ConnectionStore.load(),
              let devices = try? await APIClient(connection: connection).devices(), !devices.isEmpty else { return nil }
        let average = devices.reduce(0) { $0 + $1.score } / devices.count
        let fails = devices.reduce(0) { $0 + $1.fails }
        return fails > 0 ? "Score \(average) · \(fails) à corriger" : "Score \(average)"
    }

    /// Lecture brute d'une route du serveur pour une autre app d'Égide (Héphaïstos : température du Mac).
    /// nil si Argos n'est pas connecté.
    @MainActor
    public static func fetch(_ path: String) async throws -> Data? {
        guard let connection = ConnectionStore.load() else { return nil }
        return try await APIClient(connection: connection).send(path)
    }

    /// Appel d'une route du serveur pour une autre app d'Égide (Cerbère : demander un audit au Mac, lire le rapport).
    /// nil si Argos n'est pas connecté.
    @MainActor
    public static func call(_ path: String, method: String, json: Data?) async throws -> Data? {
        guard let connection = ConnectionStore.load() else { return nil }
        return try await APIClient(connection: connection).send(path, method: method, json: json)
    }

    /// Rien à sauvegarder : les données sont sur le serveur, et le jeton est un secret (jamais dans une sauvegarde).
    @MainActor
    public static func backup() throws -> Data? { nil }

    @MainActor
    public static func restore(_ data: Data) throws -> String { "rien à restaurer" }
}

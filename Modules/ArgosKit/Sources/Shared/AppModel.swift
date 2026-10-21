import Foundation
import Observation

/// État partagé de l'app. La façon d'obtenir la connexion dépend de la plateforme
/// (ConnectionStore) : Trousseau sur iPhone, fichier du serveur local sur Mac.
@MainActor
@Observable
final class AppModel {
    var connection: Connection?
    var devices: [DeviceSummary] = []
    var listError: String?
    var lastRefresh: Date?
    var netUnapproved = 0
    /// Écran à afficher, demandé depuis l'extérieur de la liste (lien egide://argos/…).
    var requestedRoute: Route?
    /// Action supplémentaire du bouton « Actualiser » (sur Mac : scan du réseau local).
    @ObservationIgnored var onRescan: (() -> Void)?

    init() {
        if DemoArgos.actif {
            connection = DemoArgos.connexion
            devices = DemoArgos.appareils
            netUnapproved = 1
            lastRefresh = .now
            return
        }
        connection = ConnectionStore.load()
    }

    var client: APIClient? { connection.map(APIClient.init) }

    var totalFails: Int { devices.reduce(0) { $0 + $1.fails } }
    var totalWarns: Int { devices.reduce(0) { $0 + $1.warns } }

    func refreshDevices() async {
        if DemoArgos.actif { return }
        if connection == nil { connection = ConnectionStore.load() }
        guard let client else {
            listError = ConnectionStore.missingMessage
            return
        }
        do {
            devices = try await client.devices()
            listError = nil
            if let nets = try? await client.networks() {
                netUnapproved = nets.reduce(0) { $0 + $1.unapproved }
            }
            lastRefresh = Date()
        } catch {
            listError = error.localizedDescription
            if case APIError.unauthorized = error { ConnectionStore.unauthorized(self) }
        }
    }

    /// Bouton « Actualiser » : demande un nouveau scan à tous les ordinateurs en ligne.
    /// Les nouveaux résultats arrivent dans la minute, via le rafraîchissement automatique.
    func rescanAll() async {
        if DemoArgos.actif { return }
        onRescan?()
        try? await client?.scan()
        await refreshDevices()
    }

    /// Vérifie une connexion avant de l'enregistrer.
    func connect(_ c: Connection) async throws {
        _ = try await APIClient(connection: c).devices()
        ConnectionStore.save(c)
        connection = c
        await refreshDevices()
    }

    func disconnect() {
        ConnectionStore.clear()
        connection = nil
        devices = []
    }
}

/// Analyse le lien du QR code affiché par l'app Mac : https://hote/#token=abc…
enum PairingLink {
    static func parse(_ text: String) -> Connection? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme, ["http", "https"].contains(scheme),
              let host = url.host(),
              let fragment = url.fragment, fragment.hasPrefix("token=") else { return nil }
        let token = String(fragment.dropFirst("token=".count))
        guard token.count >= 16, token.allSatisfy(\.isHexDigit) else { return nil }
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = host
        comps.port = url.port
        guard let base = comps.url else { return nil }
        return Connection(baseURL: base, token: token)
    }
}

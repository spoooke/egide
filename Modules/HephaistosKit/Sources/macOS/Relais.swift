import Foundation

/// Envoie les mesures au serveur Argos de ce Mac, qui les montre dans Égide sur l'iPhone et y relaie les alertes.
/// Tout reste sur le Mac (adresse locale) ; sans Argos installé (pas de jeton), rien n'est envoyé.
@MainActor
final class Relais {
    /// Secondes entre deux envois : une requête locale par minute ne pèse rien.
    static let intervalle = 60.0
    private static let adresse = URL(string: "http://127.0.0.1:8787/api/temperature")!
    private static let jeton = URL.applicationSupportDirectory.appending(path: "Heartbit/data/agent-token")

    private let session: URLSession = {
        let reglages = URLSessionConfiguration.ephemeral
        reglages.timeoutIntervalForRequest = 5
        return URLSession(configuration: reglages)
    }()
    private var dernier: Date?

    /// Vrai quand la mesure de la minute est due.
    func attendu(_ date: Date) -> Bool {
        dernier.map { abs(date.timeIntervalSince($0)) >= Self.intervalle } ?? true
    }

    func envoyer(_ publication: Publication, le date: Date) {
        dernier = date
        // Jeton relu à chaque envoi : Argos peut être installé, ou son jeton changé, pendant qu'Héphaïstos tourne.
        guard let jeton = try? String(contentsOf: Self.jeton, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !jeton.isEmpty, let corps = try? JSONEncoder().encode(publication) else { return }
        var requete = URLRequest(url: Self.adresse)
        requete.httpMethod = "POST"
        requete.httpBody = corps
        requete.setValue("application/json", forHTTPHeaderField: "Content-Type")
        requete.setValue("Bearer \(jeton)", forHTTPHeaderField: "Authorization")
        let session = session
        // Serveur arrêté : la mesure est perdue, la suivante part une minute plus tard.
        Task { _ = try? await session.data(for: requete) }
    }
}

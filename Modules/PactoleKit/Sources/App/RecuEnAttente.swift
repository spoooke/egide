import Foundation
import Observation
import UniformTypeIdentifiers

/// Reçu reçu de l'extérieur (« Ouvrir dans Égide », action Raccourcis, glisser sur la fenêtre du Mac) :
/// l'accueil de Money le lit et ouvre la saisie pré-remplie.
@Observable
@MainActor
final class RecuEnAttente {
    static let shared = RecuEnAttente()

    struct Fichier: Equatable {
        var data: Data
        var type: UTType
        var numero: Int
    }

    private(set) var fichier: Fichier?
    private var compteur = 0

    func deposer(_ data: Data, type: UTType) {
        compteur += 1
        fichier = Fichier(data: data, type: type, numero: compteur)
    }

    func prendre() -> Fichier? {
        defer { fichier = nil }
        return fichier
    }
}

import Foundation
import Observation

/// Demandes de navigation venues de l'extérieur (contrôle, Siri, liens `egide://muse/capture` et `muse://capture`,
/// transmis par l'onglet).
@Observable
@MainActor
final class AppNavigation {
    static let shared = AppNavigation()

    /// Incrémenté à chaque demande d'ouverture sur le champ de saisie.
    private(set) var captureRequests = 0

    func requestCapture() {
        captureRequests += 1
    }
}

import EgideUI
import LocalAuthentication
import SwiftUI

/// Verrouillage de l'onglet Argos par Face ID (ou code de l'iPhone en secours) :
/// au premier affichage, puis après une minute en arrière-plan ou sur un autre onglet.
@MainActor
@Observable
final class AppLock {
    var locked = true
    private var backgroundedAt: Date?
    private static let relockAfter: TimeInterval = 60

    func didEnterBackground() {
        // Le premier départ compte (onglet quitté puis app en arrière-plan : une seule minute en tout).
        if backgroundedAt == nil { backgroundedAt = Date() }
    }

    func willEnterForeground() {
        if let at = backgroundedAt, Date().timeIntervalSince(at) > Self.relockAfter { locked = true }
        backgroundedAt = nil
    }

    func unlock() async {
        if await Self.authenticate(reason: "Déverrouiller Argos") { locked = false }
    }

    /// Face ID, avec le code de l'iPhone en secours. Renvoie false si l'utilisateur annule.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // Aucun code ni Face ID configuré sur l'appareil (simulateur) : rien à vérifier.
            return true
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

/// Écran affiché quand l'app est verrouillée, et en aperçu dans le sélecteur d'apps
/// (pour ne pas exposer l'état des appareils).
struct LockScreen: View {
    var showsButton = true
    var onUnlock: () -> Void = {}

    var body: some View {
        VStack(spacing: 20) {
            Image("Logo", bundle: .argos)
                .resizable()
                .egideIconFrame(88)
            Text("Argos").font(.system(.title, design: .rounded, weight: .bold)).foregroundStyle(EgideTheme.encre)
            if showsButton {
                Button("Déverrouiller", systemImage: "faceid", action: onUnlock)
                    .buttonStyle(.egide)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .egideScreen()
    }
}

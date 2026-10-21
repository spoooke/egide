import SwiftUI

// Bouton « Précédent » vers l'accueil d'Égide. L'action vient de l'app (ModuleRootView(onHome:)) ;
// sans action, pas de bouton.

private struct HomeActionKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable () -> Void)? = nil
}

extension EnvironmentValues {
    var goHome: (@MainActor @Sendable () -> Void)? {
        get { self[HomeActionKey.self] }
        set { self[HomeActionKey.self] = newValue }
    }
}

/// À placer dans la barre de l'écran racine du module (les écrans suivants ont le retour système).
struct HomeToolbarItem: ToolbarContent {
    let action: (@MainActor @Sendable () -> Void)?

    var body: some ToolbarContent {
        if let action {
            ToolbarItem(placement: .aGauche) {
                Button("Précédent", systemImage: "chevron.backward", action: action)
            }
        }
    }
}

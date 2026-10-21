import EgideUI
import SwiftUI

/// Onglet Hermès d'Égide : contrôle du Mac (repris d'Hermes/iOSApp + Shared, en Swift 5).
public enum HermesKit {
    public static let title = "Hermès"
    public static let systemImage = "display"
}

/// Écran ouvert par un lien egide://hermes/…
public enum HermesRoute: Equatable {
    case connect
    case pair

    public init(path: [String]) {
        self = path.first == "pair" ? .pair : .connect
    }
}

/// Écran racine de l'onglet (seul onglet autorisé en paysage).
/// La session est coupée dès que l'onglet n'est plus affiché (`isActive` faux) ou que l'app passe en arrière-plan.
public struct HermesRootView: View {
    private let path: [String]
    private let isActive: Bool
    private let onHome: (@MainActor () -> Void)?
    @StateObject private var store = MacStore()
    @StateObject private var client = RemoteClient()
    @Environment(\.scenePhase) private var scenePhase

    /// `isActive` : onglet affiché. `onHome` : bouton « Précédent » vers l'accueil d'Égide.
    public init(path: [String] = [], isActive: Bool = true, onHome: (@MainActor () -> Void)? = nil) {
        self.path = path
        self.isActive = isActive
        self.onHome = onHome
    }

    public var body: some View {
        HomeView()
            .environmentObject(store)
            .environmentObject(client)
            .environment(\.goHome, onHome)
            // Thème sombre propre à l'onglet (le reste d'Égide garde le réglage de l'iPhone).
            .environment(\.colorScheme, .dark)
            .tint(EgideTheme.bleu)
            .onChange(of: isActive) { _, active in
                if !active { client.disconnect() }
            }
            .onChange(of: scenePhase) { _, phase in
                // Jamais de session en arrière-plan.
                if phase == .background { client.disconnect() }
            }
    }
}

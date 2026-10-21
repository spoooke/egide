import EgideUI
import SwiftUI

/// Onglet Pactole d'Égide (nom de code : Money) : dépenses et reste à dépenser de la semaine (roadmap Money dans ROADMAP.md).
public enum PactoleKit {
    public static let title = "Pactole"
    public static let systemImage = "wallet.bifold"
}

/// Écran ouvert par un lien egide://money/…
public enum PactoleRoute: Equatable {
    /// Reste de la semaine.
    case week
    /// Saisie éclair d'une dépense.
    case add

    public init(path: [String]) {
        self = path.first == "add" ? .add : .week
    }
}

/// Écran racine de l'onglet. `path` : chemin du dernier lien egide://money/… reçu ; `request` change à chaque lien,
/// même identique au précédent (deux saisies éclair de suite).
public struct PactoleRootView: View {
    private let path: [String]
    private let request: Int
    private let onHome: (@MainActor @Sendable () -> Void)?
    private let icone: Image?

    /// `onHome` : bouton « Précédent » vers l'accueil d'Égide. `icone` : en-tête de l'écran sur le Mac.
    public init(path: [String] = [], request: Int = 0, onHome: (@MainActor @Sendable () -> Void)? = nil, icone: Image? = nil) {
        self.path = path
        self.request = request
        self.onHome = onHome
        self.icone = icone
    }

    public var body: some View {
        PactoleHomeView(route: PactoleRoute(path: path), request: request, icone: icone)
            .modelContainer(PactoleDatabase.container)
            .environment(\.goHome, onHome)
            .tint(EgideTheme.bleu)
    }
}

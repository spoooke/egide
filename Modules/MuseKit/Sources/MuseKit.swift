import EgideUI
import SwiftData
import SwiftUI

/// Onglet Muse d'Égide : idées, rappels et roadmaps (repris de Muse/Muse, sans la version Mac).
public enum MuseKit {
    public static let title = "Muse"
    public static let systemImage = "lightbulb"
}

/// Écran ouvert par un lien egide://muse/… ou muse://…
public enum MuseRoute: Equatable {
    case ideas
    /// Saisie rapide (muse://capture, contrôle de l'écran verrouillé, Siri).
    case capture

    public init(path: [String]) {
        self = path.first == "capture" ? .capture : .ideas
    }
}

/// Écran racine de l'onglet. `path` : chemin du dernier lien reçu ; `request` change à chaque lien,
/// même identique au précédent (deux saisies rapides de suite).
public struct MuseRootView: View {
    private let path: [String]
    private let request: Int
    private let onHome: (@MainActor @Sendable () -> Void)?
    @Environment(\.scenePhase) private var scenePhase

    /// `onHome` : bouton « Précédent » vers l'accueil d'Égide.
    public init(path: [String] = [], request: Int = 0, onHome: (@MainActor @Sendable () -> Void)? = nil) {
        self.path = path
        self.request = request
        self.onHome = onHome
    }

    public var body: some View {
        ContentView()
            .modelContainer(AppDatabase.container)
            .environment(\.goHome, onHome)
            .tint(EgideTheme.bleu)
            .onChange(of: request, initial: true) { _, _ in
                if MuseRoute(path: path) == .capture { AppNavigation.shared.requestCapture() }
            }
            // Synchro immédiate à l'ouverture et au retour dans l'app.
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { Task { await SyncService.shared.sync() } }
            }
    }
}

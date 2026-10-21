import EgideUI
import SwiftUI

/// Onglet Argos d'Égide : client du serveur Argos (repris d'Argos/argos/apple). Sur iPhone, connexion par QR code
/// et onglet verrouillé par Face ID ; sur Mac, connexion directe au serveur installé sur la machine.
public enum ArgosKit {
    public static let title = "Argos"
    public static let systemImage = "shield.lefthalf.filled"
}

/// Écran ouvert par un lien egide://argos/…
public enum ArgosRoute: Equatable {
    case dashboard
    case device(String)
    case network
    case events

    public init(path: [String]) {
        switch path.first {
        case "device" where path.count > 1: self = .device(path[1])
        case "network": self = .network
        case "events": self = .events
        default: self = .dashboard
        }
    }

    /// Écran de la liste à ouvrir (nil : la liste elle-même).
    var route: Route? {
        switch self {
        case .dashboard: nil
        case .device(let id): .device(id)
        case .network: .network
        case .events: .events
        }
    }
}

extension Bundle {
    /// Ressources du module (logo, couleur d'Argos).
    static let argos = Bundle(for: AppModel.self)
}

/// Écran racine de l'onglet. `path` : chemin du dernier lien egide://argos/… reçu.
public struct ArgosRootView: View {
    private let path: [String]
    private let onHome: (@MainActor () -> Void)?
    @State private var model = AppModel()
    #if os(iOS)
    @State private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase
    #endif

    /// `onHome` : bouton « Précédent » vers l'accueil d'Égide.
    public init(path: [String] = [], onHome: (@MainActor () -> Void)? = nil) {
        self.path = path
        self.onHome = onHome
        #if DEBUG && os(iOS)
        // Simulateur avec lien de test : pas de Face ID ni de code (voir plus bas).
        if Self.debugPairingLink != nil {
            let lock = AppLock()
            lock.locked = false
            _lock = State(initialValue: lock)
        }
        #endif
    }

    #if DEBUG && os(iOS)
    private static let debugPairingLink = ProcessInfo.processInfo.environment["ARGOS_PAIRING_LINK"].flatMap(PairingLink.parse)
    #endif

    public var body: some View {
        #if os(iOS)
        ZStack {
            Group {
                if model.connection == nil {
                    LoginView()
                } else {
                    DeviceListView()
                }
            }
            // Une fois connecté, l'onglet s'ouvre avec Face ID. Aperçu masqué dans le sélecteur d'apps.
            if model.connection != nil && lock.locked {
                LockScreen { Task { await lock.unlock() } }
                    .task { await lock.unlock() }
            } else if scenePhase != .active {
                LockScreen(showsButton: false)
            }
        }
        .environment(model)
        .environment(\.goHome, onHome)
        .tint(EgideTheme.bleu)
        // Quitter l'onglet compte comme passer en arrière-plan.
        .onAppear { lock.willEnterForeground() }
        .onDisappear { lock.didEnterBackground() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: lock.didEnterBackground()
            case .active: lock.willEnterForeground()
            default: break
            }
        }
        .onChange(of: path, initial: true) { _, path in
            model.requestedRoute = ArgosRoute(path: path).route
        }
        #if DEBUG
        // Tests dans le simulateur uniquement (absent des versions installées) :
        // SIMCTL_CHILD_ARGOS_PAIRING_LINK=… xcrun simctl launch booted com.spoooke.egide
        .task {
            if model.connection == nil, let c = Self.debugPairingLink {
                try? await model.connect(c)
            }
        }
        #endif
        #else
        DeviceListView()
            .environment(model)
            .tint(EgideTheme.bleu)
            .onChange(of: path, initial: true) { _, path in
                model.requestedRoute = ArgosRoute(path: path).route
            }
        #endif
    }
}

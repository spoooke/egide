import Observation

/// Lien transmis à un module : chemin, et numéro de demande (change même si le chemin est identique).
struct ModuleLink: Equatable {
    var path: [String]
    var request: Int
}

/// Navigation venue de l'extérieur : liens egide:// et muse://, Siri, Raccourcis, contrôle de l'écran verrouillé.
@Observable
@MainActor
final class AppRouter {
    static let shared = AppRouter()

    struct TabRequest: Equatable {
        var target: DeepLink.Target
        var request: Int
    }

    private(set) var links: [Module: ModuleLink] = [:]
    /// Dernier onglet demandé ; l'onglet affiché le suit.
    private(set) var tabRequest: TabRequest?
    private var counter = 0

    func open(_ target: DeepLink.Target, path: [String] = []) {
        counter += 1
        switch target {
        case .module(let module):
            links[module] = ModuleLink(path: path, request: counter)
        case .settings:
            break
        }
        tabRequest = TabRequest(target: target, request: counter)
    }

    func open(_ link: DeepLink) {
        open(link.target, path: link.path)
    }
}

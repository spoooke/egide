import Foundation

/// Lien ouvert dans Égide : egide://<module>/<chemin…>, ou muse://<chemin…> (ancien schéma de Muse,
/// gardé pour les raccourcis et le contrôle de l'écran verrouillé existants).
/// egide://cerbere/audit?lien=<lien> (extension de partage) : le lien devient le dernier élément du chemin.
struct DeepLink: Equatable {
    enum Target: Equatable {
        case module(Module)
        case settings
    }

    let target: Target
    let path: [String]

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let segments = components.path.split(separator: "/").map(String.init)
        let host = components.host?.lowercased()
        switch scheme {
        case "muse":
            // muse://capture → egide://muse/capture
            target = .module(.muse)
            path = (host.map { [$0] } ?? []) + segments
        case "egide":
            guard let host else { return nil }
            if host == "settings" || host == "reglages" {
                target = .settings
            } else if let module = Module(rawValue: host) {
                target = .module(module)
            } else {
                return nil
            }
            // Le lien à auditer arrive en paramètre : Cerbère le montre dans son champ, sans rien envoyer.
            path = segments + (components.queryItems?.first { $0.name == "lien" }?.value.map { [$0] } ?? [])
        default:
            return nil
        }
    }
}

import AppKit
import EgideUI

/// Captures pour le README : `-egide.demo YES -egide.captures <dossier>` ouvre chaque onglet tour à tour et
/// enregistre la fenêtre en PNG (accueil.png, pactole.png…), puis quitte. Seulement en mode démo, pour ne jamais
/// photographier de vraies données ; l'app dessine sa propre fenêtre, sans droit d'enregistrement de l'écran.
@MainActor
enum Captures {
    static func lancerSiDemande(_ etat: EtatEgide) {
        guard EgideDemo.actif, let chemin = UserDefaults.standard.string(forKey: "egide.captures") else { return }
        let dossier = URL(filePath: chemin, directoryHint: .isDirectory)
        Task {
            try? FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
            // Le temps que la fenêtre s'ouvre et que les premières mesures arrivent.
            try? await Task.sleep(for: .seconds(4))
            for onglet in Onglet.allCases {
                etat.onglet = onglet
                try? await Task.sleep(for: .seconds(1.5))
                enregistrer(dans: dossier.appending(path: "\(onglet.rawValue).png"))
            }
            NSApp.terminate(nil)
        }
    }

    private static func enregistrer(dans fichier: URL) {
        guard let fenetre = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "Égide" }),
              let vue = fenetre.contentView?.superview ?? fenetre.contentView,
              let image = vue.bitmapImageRepForCachingDisplay(in: vue.bounds) else { return }
        vue.cacheDisplay(in: vue.bounds, to: image)
        try? image.representation(using: .png, properties: [:])?.write(to: fichier)
    }
}

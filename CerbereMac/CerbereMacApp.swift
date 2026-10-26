import CerbereKit
import EgideUI
import SwiftUI

/// Cerbère sur le Mac : coller un lien ou glisser un dossier, suivre l'audit, lire le rapport, retrouver les
/// audits passés et comparer deux versions. Rien de ce qui est audité n'est exécuté, ni rendu autrement qu'en texte.
@main
struct CerbereMacApp: App {
    @NSApplicationDelegateAdaptor(Delegue.self) private var delegue
    @State private var modele = Modele()

    var body: some Scene {
        Window("Cerbère", id: "main") {
            Fenetre(modele: modele)
                .frame(minWidth: 900, minHeight: 600)
                .egideApparence()
        }
        .defaultSize(width: 1100, height: 760)

        // Audits en cours (app, outil, iPhone) et leur journal en direct.
        Window("Travail en cours", id: "travail") {
            VueTravail().frame(minWidth: 760, minHeight: 460).egideApparence()
        }
        .defaultSize(width: 980, height: 640)
        .keyboardShortcut("j")
    }
}

final class Delegue: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

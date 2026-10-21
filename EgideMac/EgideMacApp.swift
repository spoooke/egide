import CerbereKit
import HephaistosKit
import SwiftUI

/// Égide sur le Mac : une fenêtre, un onglet par outil, et une seule icône dans la barre des menus
/// (le bouclier d'Égide ; la température est dans le menu).
@main
struct EgideMacApp: App {
    @State private var etat = EtatEgide()

    var body: some Scene {
        Window("Égide", id: "main") {
            FenetreEgide(etat: etat)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)

        // Audits en cours (app, outil, iPhone) et leur journal en direct, ouvert depuis l'onglet Cerbère.
        Window("Travail en cours", id: "travail") {
            VueTravail().frame(minWidth: 760, minHeight: 460)
        }
        .defaultSize(width: 980, height: 640)
        .keyboardShortcut("j")

        MenuBarExtra {
            BarreDesMenus(etat: etat)
        } label: {
            Image(nsImage: IconeBarre.image)
                .accessibilityLabel("Égide, température du Mac : \(etat.hephaistos.texte)")
        }
        .menuBarExtraStyle(.window)
    }
}

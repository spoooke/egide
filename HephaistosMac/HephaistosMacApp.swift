import HephaistosKit
import EgideUI
import SwiftUI

/// Héphaïstos : la température du Mac dans la barre des menus, le détail dans la fenêtre qui s'ouvre au clic.
@main
struct HephaistosMacApp: App {
    private let modele: HephaistosModele
    private let notifications: Notifications

    init() {
        let modele = HephaistosModele()
        let notifications = Notifications()
        modele.surAlerte = { notifications.envoyer($0) }
        modele.demarrer()
        self.modele = modele
        self.notifications = notifications
        if modele.reglagesAlerte.active || modele.reglagesRessources.memoire || modele.reglagesRessources.disque { Task { await notifications.verifier() } }
    }

    var body: some Scene {
        MenuBarExtra {
            Panneau(modele: modele, notifications: notifications).egideMenuBar()
        } label: {
            Etiquette(modele: modele)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Chiffre de la barre des menus : un simple texte, qui ne dépend que de `modele.texte`.
private struct Etiquette: View {
    let modele: HephaistosModele

    var body: some View {
        Text(modele.texte)
            .monospacedDigit()
            .accessibilityLabel("Température du Mac : \(modele.texte)")
    }
}

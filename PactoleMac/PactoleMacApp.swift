import PactoleKit
import SwiftUI

/// Pactole (nom de code : Money) sur le Mac : même onglet que dans Égide sur l'iPhone, dans une fenêtre,
/// et le reste de la semaine dans la barre des menus. Synchro avec l'iPhone par iCloud Drive (Réglages › Synchro).
@main
struct PactoleMacApp: App {
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Fenêtre unique : « Ouvrir Pactole » ramène la fenêtre existante au lieu d'en créer une autre.
        Window("Pactole", id: "main") {
            PactoleRootView()
                .frame(minWidth: 440, minHeight: 640)
                // « Ouvrir avec › Pactole » ou PDF glissé sur l'icône : saisie pré-remplie.
                .onOpenURL { PactoleKit.recevoirRecu($0) }
        }

        MenuBarExtra {
            PactoleMenuBarContent {
                openWindow(id: "main")
                NSApplication.shared.activate()
            }
        } label: {
            PactoleMenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

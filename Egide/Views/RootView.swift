import PactoleKit
import SwiftUI

/// Écran d'accueil d'Égide (les icônes des apps) ; une app s'ouvre en plein écran, avec un zoom depuis son icône,
/// et son bouton « Précédent » ramène à l'accueil. Réglages s'ouvre depuis l'accueil.
struct RootView: View {
    @AppStorage("tabLayout") private var tabLayoutStorage = TabLayout.standard.storage
    @SceneStorage("selectedTab") private var ouvertID = "home"
    @State private var router = AppRouter.shared
    @State private var showsSettings = false
    @Namespace private var zoom

    private var layout: Binding<TabLayout> {
        Binding(get: { TabLayout(storage: tabLayoutStorage) },
                set: { tabLayoutStorage = $0.storage })
    }

    /// App ouverte (nil : écran d'accueil). Gardée d'un lancement à l'autre, comme l'onglet avant.
    private var ouvert: Binding<Module?> {
        Binding(get: { Module(rawValue: ouvertID) },
                set: { ouvertID = $0?.rawValue ?? "home" })
    }

    var body: some View {
        HomeView(layout: layout, showsSettings: $showsSettings, zoom: zoom) { ouvert.wrappedValue = $0 }
            .fullScreenCover(item: ouvert) { module in
                module.rootView(link: router.links[module], isActive: true) { ouvert.wrappedValue = nil }
                    .navigationTransition(.zoom(sourceID: module, in: zoom))
            }
            .onChange(of: ouvert.wrappedValue, initial: true) { _, module in
                AppDelegate.setOrientations(module?.orientations ?? .portrait)
            }
            .onOpenURL { url in
                // « Ouvrir dans Égide » d'un PDF, d'une image ou d'un mail : reçu pour Pactole.
                if url.isFileURL {
                    if PactoleKit.recevoirRecu(url) { router.open(.module(.money)) }
                } else if let link = DeepLink(url: url) {
                    router.open(link)
                }
            }
            // Liens, Raccourcis, contrôle de l'écran verrouillé : ouvre l'app demandée.
            .onChange(of: router.tabRequest, initial: true) { _, request in
                guard let target = request?.target else { return }
                switch target {
                case .module(let module):
                    // Un lien vers une app masquée la réaffiche.
                    if layout.wrappedValue.hidden.contains(module) {
                        layout.wrappedValue.setHidden(module, false)
                    }
                    ouvert.wrappedValue = module
                case .settings:
                    ouvert.wrappedValue = nil
                    showsSettings = true
                }
            }
    }
}

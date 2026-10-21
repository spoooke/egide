import HephaistosKit
import Observation
import SwiftUI

/// Les outils d'Égide sur le Mac, un onglet chacun.
enum Onglet: String, CaseIterable, Identifiable {
    case accueil, hephaistos, pactole, muse, iris, cerbere, argos, hermes

    var id: String { rawValue }

    var titre: String {
        switch self {
        case .accueil: "Accueil"
        case .hephaistos: "Héphaïstos"
        case .pactole: "Pactole"
        case .muse: "Muse"
        case .iris: "Iris"
        case .cerbere: "Cerbère"
        case .argos: "Argos"
        case .hermes: "Hermès"
        }
    }

    var sousTitre: String {
        switch self {
        case .accueil: ""
        case .hephaistos: "Températures, mémoire et disque"
        case .pactole: "Budget de la semaine"
        case .muse: "Idées, rappels, projets"
        case .iris: "Scans de l'iPhone, rangés par genre"
        case .cerbere: "Auditer un dépôt, une app ou un fichier"
        case .argos: "Surveillance des machines"
        case .hermes: "Piloter le Mac depuis l'iPhone"
        }
    }

    var symbole: String {
        switch self {
        case .accueil: "square.grid.2x2"
        case .hephaistos: "thermometer.medium"
        case .pactole: "wallet.bifold"
        case .muse: "lightbulb"
        case .iris: "doc.viewfinder"
        case .cerbere: "checkmark.shield"
        case .argos: "shield.lefthalf.filled"
        case .hermes: "iphone.and.arrow.forward"
        }
    }

    /// Icône de l'outil, la même que sur l'iPhone.
    var icone: String {
        switch self {
        case .accueil: "Icone-egide"
        case .hephaistos: "Icone-hephaistos"
        case .pactole: "Icone-money"
        case .muse: "Icone-muse"
        case .iris: "Icone-iris"
        case .cerbere: "Icone-cerbere"
        case .argos: "Icone-argos"
        case .hermes: "Icone-hermes"
        }
    }
}

/// Ce que la fenêtre et la barre des menus partagent : l'onglet ouvert et les modèles qui tournent
/// tant que l'app est lancée (mesures d'Héphaïstos, historique de Cerbère).
@MainActor
@Observable
final class EtatEgide {
    var onglet = Onglet.accueil
    let hephaistos: HephaistosModele
    let notifications: Notifications
    let cerbere: Modele

    init() {
        Reprise.reglagesDesAnciennesApps()
        let hephaistos = HephaistosModele()
        let notifications = Notifications()
        hephaistos.surAlerte = { notifications.envoyer($0) }
        hephaistos.demarrer()
        self.hephaistos = hephaistos
        self.notifications = notifications
        cerbere = Modele()
        if hephaistos.reglagesAlerte.active || hephaistos.reglagesRessources.memoire || hephaistos.reglagesRessources.disque {
            Task { await notifications.verifier() }
        }
    }
}

/// Au premier lancement, Égide reprend les réglages de Pactole, Héphaïstos et Cerbère, qui étaient des apps
/// séparées. Les données ne bougent pas : la base de Pactole et les rapports de Cerbère sont déjà à un endroit
/// commun (Application Support, Caches), seules les préférences dépendaient de l'identifiant de chaque app.
enum Reprise {
    static let anciennesApps = ["com.spoooke.money", "com.spoooke.hephaistos", "com.spoooke.cerbere"]

    static func reglagesDesAnciennesApps() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "egide.repriseFaite") else { return }
        for domaine in anciennesApps {
            for (cle, valeur) in defaults.persistentDomain(forName: domaine) ?? [:] where garder(cle) && defaults.object(forKey: cle) == nil {
                defaults.set(valeur, forKey: cle)
            }
        }
        defaults.set(true, forKey: "egide.repriseFaite")
    }

    /// Les clés du système (position des fenêtres, etc.) et l'inscription à l'ouverture de session restent à l'ancienne app.
    static func garder(_ cle: String) -> Bool {
        !cle.hasPrefix("NS") && !cle.hasPrefix("Apple") && !cle.hasPrefix("com.apple") && cle != "hephaistos.ouvertureInscrite"
    }
}

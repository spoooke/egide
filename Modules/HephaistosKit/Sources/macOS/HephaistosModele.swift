import AppKit
import Foundation
import Observation

/// Chiffre montré dans la barre des menus.
public enum Affichage: String, CaseIterable, Identifiable, Sendable {
    case plusChaud = "Point le plus chaud"
    case processeur = "Moyenne du processeur"

    public var id: String { rawValue }

    public func degres(_ releve: Releve) -> Double? {
        switch self {
        case .plusChaud: releve.plusChaud
        case .processeur: releve.processeurMoyenne
        }
    }
}

/// Mesures en continu. La barre des menus ne lit que `texte`, qui ne change que si le chiffre affiché change :
/// rien n'est redessiné entre-temps (leçon de Pactole : un label qui se réévalue en boucle occupe un cœur entier).
/// Le reste (`releve`, `historique`, `sondes`, `apps`) n'est publié que fenêtre ouverte : SwiftUI garde la fenêtre fermée
/// en mémoire et la recalculerait à chaque mesure.
/// Les alertes ne coûtent rien de plus en fond : une comparaison par mesure ; l'app qui chauffe n'est cherchée
/// qu'au moment d'alerter, et les apps qui occupent la mémoire une fois par minute (pour l'iPhone).
@MainActor
@Observable
public final class HephaistosModele {
    public struct Point: Identifiable, Equatable, Sendable {
        public let date: Date
        public let degres: Double
        public var id: Date { date }
    }

    /// Secondes entre deux mesures.
    public nonisolated static let intervalle = 2.0
    /// Nombre de mesures moyennées pour le chiffre affiché (10 s) : le cœur le plus chaud saute de 25 °C
    /// d'une mesure à l'autre dès qu'une tâche démarre, un chiffre brut serait illisible.
    public nonisolated static let lissage = 5
    /// Durée de la courbe.
    public nonisolated static let duree = 600.0

    public private(set) var texte = "…"
    /// Chiffre affiché en grand dans la fenêtre : le même que `texte`, mais publié seulement fenêtre ouverte.
    public private(set) var chiffre = "…"
    public private(set) var releve: Releve?
    public private(set) var historique: [Point] = []
    /// Liste complète des capteurs, relevée seulement quand `detail` est demandé.
    public private(set) var sondes: [Sonde] = []
    /// Les apps qui occupent le plus de mémoire, relevées toutes les 10 s fenêtre ouverte.
    public private(set) var apps: [Occupation] = []
    /// À tenir à jour par la fenêtre (à son apparition et à sa disparition).
    public var fenetreOuverte = false {
        didSet {
            if fenetreOuverte {
                apps = occupations()
                publier()
            } else if detail {
                detail = false
            }
        }
    }
    public var detail = false {
        didSet { sondes = detail ? lecteur.sondes() : [] }
    }
    public var affichage: Affichage {
        didSet {
            UserDefaults.standard.set(affichage.rawValue, forKey: Self.cleAffichage)
            memoire = []
            recents = []
            if let dernier {
                recents = affichage.degres(dernier).map { [$0] } ?? []
                texte = Self.texte(Self.moyenne(recents))
            }
            publier()
        }
    }

    /// Réglages de l'alerte de température (toujours jugée sur le point le plus chaud, moyenné sur 10 s).
    public var reglagesAlerte: ReglagesAlerte {
        didSet {
            guard reglagesAlerte != oldValue else { return }
            let reglages = UserDefaults.standard
            reglages.set(reglagesAlerte.active, forKey: Self.cleAlerte)
            reglages.set(reglagesAlerte.seuil, forKey: Self.cleSeuil)
            reglages.set(reglagesAlerte.duree, forKey: Self.cleDuree)
        }
    }
    /// Réglages des alertes de mémoire et de disque.
    public var reglagesRessources: ReglagesRessources {
        didSet {
            guard reglagesRessources != oldValue else { return }
            let reglages = UserDefaults.standard
            reglages.set(reglagesRessources.memoire, forKey: Self.cleMemoire)
            reglages.set(reglagesRessources.disque, forKey: Self.cleDisque)
            reglages.set(reglagesRessources.seuilDisque, forKey: Self.cleSeuilDisque)
        }
    }
    /// Dernière alerte envoyée depuis le lancement.
    public private(set) var dernierAvis: Avis?
    /// Appelé à chaque alerte, pour l'envoyer en notification.
    @ObservationIgnored public var surAlerte: (@MainActor (Avis) -> Void)?

    private static let cleAffichage = "hephaistos.affichage"
    private static let cleAlerte = "hephaistos.alerte.active"
    private static let cleSeuil = "hephaistos.alerte.seuil"
    private static let cleDuree = "hephaistos.alerte.duree"
    private static let cleMemoire = "hephaistos.alerte.memoire"
    private static let cleDisque = "hephaistos.alerte.disque"
    private static let cleSeuilDisque = "hephaistos.alerte.seuilDisque"
    @ObservationIgnored private let lecteur = Lecteur()
    @ObservationIgnored private var boucle: Task<Void, Never>?
    /// Dernière mesure et courbe, tenues à jour même fenêtre fermée.
    @ObservationIgnored private var dernier: Releve?
    @ObservationIgnored private var memoire: [Point] = []
    /// Dernières valeurs brutes du chiffre affiché, pour la moyenne glissante.
    @ObservationIgnored private var recents: [Double] = []
    /// Dernières valeurs brutes du point le plus chaud, pour l'alerte.
    @ObservationIgnored private var chauds: [Double] = []
    @ObservationIgnored private var veille = Veille()
    @ObservationIgnored private var episodeMemoire = Episode()
    @ObservationIgnored private var episodeDisque = Episode()
    /// Mesures faites fenêtre ouverte, pour ne relever les apps qu'une fois sur `lissage`.
    @ObservationIgnored private var tours = 0
    @ObservationIgnored private let relais = Relais()

    public init() {
        let reglages = UserDefaults.standard
        affichage = reglages.string(forKey: Self.cleAffichage).flatMap(Affichage.init) ?? .plusChaud
        let defaut = ReglagesAlerte.parDefaut
        reglagesAlerte = ReglagesAlerte(active: reglages.object(forKey: Self.cleAlerte) as? Bool ?? defaut.active,
                                        seuil: reglages.object(forKey: Self.cleSeuil) as? Double ?? defaut.seuil,
                                        duree: reglages.object(forKey: Self.cleDuree) as? Double ?? defaut.duree)
        let ressources = ReglagesRessources.parDefaut
        reglagesRessources = ReglagesRessources(memoire: reglages.object(forKey: Self.cleMemoire) as? Bool ?? ressources.memoire,
                                                disque: reglages.object(forKey: Self.cleDisque) as? Bool ?? ressources.disque,
                                                seuilDisque: reglages.object(forKey: Self.cleSeuilDisque) as? Double ?? ressources.seuilDisque)
    }

    /// Lance les mesures (sans effet si elles tournent déjà).
    public func demarrer() {
        guard boucle == nil else { return }
        boucle = Task { [weak self] in
            while !Task.isCancelled {
                self?.mesurer()
                // Tolérance large : le système regroupe les réveils, l'app ne coûte presque rien.
                try? await Task.sleep(for: .seconds(Self.intervalle), tolerance: .seconds(Self.intervalle / 4))
            }
        }
    }

    private func mesurer() {
        let mesure = lecteur.releve(carteGraphique: fenetreOuverte || relais.attendu(.now))
        dernier = mesure
        if let brut = affichage.degres(mesure) {
            recents = Array((recents + [brut]).suffix(Self.lissage))
        }
        let degres = Self.moyenne(recents)
        let nouveau = Self.texte(degres)
        if nouveau != texte { texte = nouveau }
        if let degres {
            memoire = Self.ajouter(Point(date: mesure.date, degres: degres), a: memoire)
            // Pas avant la première moyenne complète : une mesure brute isolée saute de 25 °C.
            if recents.count == Self.lissage, relais.attendu(mesure.date) { relais.envoyer(Self.publication(mesure, degres: degres, apps: occupations()), le: mesure.date) }
        }
        if let brut = mesure.plusChaud {
            chauds = Array((chauds + [brut]).suffix(Self.lissage))
            if let chaud = Self.moyenne(chauds), veille.observer(chaud, le: mesure.date, reglages: reglagesAlerte) {
                alerter(chaud)
            }
        }
        surveiller(mesure)
        guard fenetreOuverte else { return }
        tours += 1
        if tours % Self.lissage == 0 { apps = occupations() }
        publier()
        if detail { sondes = lecteur.sondes() }
    }

    /// Envoie une alerte d'essai avec la température du moment, pour vérifier les notifications.
    public func essayerAlerte() {
        guard let chaud = Self.moyenne(chauds) else { return }
        alerter(chaud, essai: true)
    }

    /// Alertes de mémoire (pression tenue) et de disque (espace libre sous le seuil), une seule par épisode.
    private func surveiller(_ mesure: Releve) {
        let reglages = reglagesRessources
        if !reglages.memoire {
            episodeMemoire = Episode()
        } else if let memoire = mesure.memoire,
                  episodeMemoire.observer(depasse: memoire.pression > .normale, rearme: memoire.pression == .normale,
                                          le: mesure.date, duree: ReglagesRessources.dureeMemoire) {
            signaler(.memoire(memoire, apps: occupations(), le: mesure.date))
        }
        if !reglages.disque {
            episodeDisque = Episode()
        } else if let disque = mesure.disque,
                  episodeDisque.observer(depasse: disque.libre < reglages.seuilDisque * ReglagesRessources.giga,
                                         rearme: disque.libre >= (reglages.seuilDisque + ReglagesRessources.margeDisque) * ReglagesRessources.giga,
                                         le: mesure.date, duree: 0) {
            signaler(.disque(disque, seuil: reglages.seuilDisque, le: mesure.date))
        }
    }

    /// Apps ouvertes : identifiant de processus → nom.
    private func ouvertes() -> [pid_t: String] {
        let ouvertes = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return Dictionary(ouvertes.map { ($0.processIdentifier, $0.localizedName ?? "App sans nom") }) { premier, _ in premier }
    }

    private func occupations() -> [Occupation] { Ressources.apps(ouvertes()) }

    /// Cherche l'app qui chauffe (une seconde de mesure) puis signale l'alerte.
    private func alerter(_ degres: Double, essai: Bool = false) {
        let reglages = reglagesAlerte
        let apps = ouvertes()
        let premierPlan = NSWorkspace.shared.frontmostApplication?.processIdentifier
        Task { [weak self] in
            let classement = await Gourmands.mesurer(apps: apps, premierPlan: premierPlan)
            let alerte = Alerte(date: .now, degres: degres, reglages: reglages, diagnostic: Diagnostic(classement), essai: essai)
            self?.signaler(alerte.avis, degres: alerte.degres, essai: essai)
        }
    }

    /// Annonce l'alerte : notification du Mac, fenêtre, et serveur Argos (avec la mesure du moment) pour l'iPhone.
    /// `degres` : température de l'alerte (0 pour la mémoire et le disque).
    private func signaler(_ avis: Avis, degres: Double = 0, essai: Bool = false) {
        dernierAvis = avis
        surAlerte?(avis)
        guard let dernier, let moyenne = Self.moyenne(recents) else { return }
        let distante = AlerteDistante(degres: degres, titre: avis.titre, resume: avis.resume, detail: avis.detail, essai: essai,
                                      sorte: avis.sorte.distante)
        relais.envoyer(Self.publication(dernier, degres: moyenne, apps: occupations(), alerte: distante), le: dernier.date)
    }

    nonisolated static func publication(_ releve: Releve, degres: Double, apps: [Occupation]? = nil, alerte: AlerteDistante? = nil) -> Publication {
        let ventilateur = releve.ventilateurs.max { $0.toursParMinute < $1.toursParMinute }
        return Publication(degres: degres, ventilateur: ventilateur?.toursParMinute ?? 0, ventilateurMaxi: ventilateur?.maxi ?? 0,
                           charge: min(1, max(0, releve.charge ?? 0)), carteGraphique: releve.carteGraphique,
                           memoire: releve.memoire, appsMemoire: apps,
                           disque: releve.disque, alerte: alerte)
    }

    private func publier() {
        chiffre = texte
        releve = dernier
        historique = memoire
    }

    public nonisolated static func moyenne(_ valeurs: [Double]) -> Double? {
        valeurs.isEmpty ? nil : valeurs.reduce(0, +) / Double(valeurs.count)
    }

    public nonisolated static func texte(_ degres: Double?) -> String {
        degres.map { "\(Int($0.rounded()))°" } ?? "–"
    }

    /// Ajoute un point et retire ceux qui sortent de la fenêtre de `duree` secondes.
    public nonisolated static func ajouter(_ point: Point, a historique: [Point], duree: Double = HephaistosModele.duree) -> [Point] {
        historique.filter { point.date.timeIntervalSince($0.date) <= duree && $0.date < point.date } + [point]
    }
}

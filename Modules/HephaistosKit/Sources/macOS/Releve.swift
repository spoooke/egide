import Foundation

/// Un capteur et sa température.
public struct Sonde: Identifiable, Equatable, Sendable {
    public let id: String
    public let nom: String
    public let famille: Famille
    public let degres: Double

    public init(id: String, nom: String, famille: Famille, degres: Double) {
        self.id = id
        self.nom = nom
        self.famille = famille
        self.degres = degres
    }
}

/// Regroupement des capteurs, d'après l'essai sous charge du 12 octobre 2026 sur le MacBook Pro M4 (Mac16,1) :
/// 4 cœurs performance à fond, puis charge graphique Metal, 40 s chacun.
/// - clés SMC `Tp…` : +24 à +42 °C sous charge processeur ; elles montent aussi sous charge graphique (même puce) ;
/// - clés SMC `Tg…` : les plus sensibles à la charge graphique (+64 à +71 °C, contre +46 à +54 °C sous charge
///   processeur) ; au repos elles lisent 10 à 16 °C, moins que l'air ambiant : la puce graphique dort ;
/// - clés SMC `TB…` et capteurs HID « gas gauge battery » : batterie (moins de 2 °C d'écart pendant l'essai) ;
/// - capteur HID « NAND CH0 temp » : SSD.
/// Les autres clés ne sont pas interprétées : elles n'apparaissent que dans la liste complète.
public enum Famille: String, CaseIterable, Sendable {
    case processeur = "Processeur"
    case graphique = "Puce graphique"
    case batterie = "Batterie"
    case ssd = "SSD"
    case autreSMC = "Autres clés SMC"
    case autreHID = "Autres capteurs HID"

    public static func smc(_ cle: String) -> Famille {
        if cle.hasPrefix("Tp") { .processeur } else if cle.hasPrefix("Tg") { .graphique } else if cle.hasPrefix("TB") { .batterie } else { .autreSMC }
    }

    public static func hid(_ nom: String) -> Famille {
        if nom == Famille.nomSSD { .ssd } else if nom.hasPrefix("gas gauge battery") { .batterie } else { .autreHID }
    }

    static let nomSSD = "NAND CH0 temp"
}

public struct Ventilateur: Equatable, Sendable {
    public var toursParMinute: Double
    public var mini: Double
    public var maxi: Double

    public init(toursParMinute: Double, mini: Double, maxi: Double) {
        self.toursParMinute = toursParMinute
        self.mini = mini
        self.maxi = maxi
    }

    /// Position entre l'arrêt et la vitesse maximale, de 0 à 1.
    public var part: Double {
        maxi > 0 ? min(1, max(0, toursParMinute / maxi)) : 0
    }
}

/// Résumé d'une mesure : ce qu'affichent la barre des menus et le haut de la fenêtre.
public struct Releve: Equatable, Sendable {
    public var date: Date
    public var processeurMoyenne: Double?
    public var processeurMax: Double?
    /// nil quand la puce graphique dort (ses capteurs lisent alors moins que la batterie).
    public var graphique: Double?
    public var batterie: Double?
    public var ssd: Double?
    public var ventilateurs: [Ventilateur]
    /// Charge du processeur, de 0 à 1.
    public var charge: Double?
    /// Relevée seulement fenêtre ouverte et pour l'envoi de la minute.
    public var carteGraphique: CarteGraphique?
    public var memoire: Memoire?
    /// Relu une fois par minute seulement.
    public var disque: Disque?

    /// Point le plus chaud de la puce (processeur et puce graphique).
    public var plusChaud: Double? {
        [processeurMax, graphique].compactMap(\.self).max()
    }

    /// Un capteur débranché renvoie 0 ou une valeur absurde (−9201 °C sur deux capteurs HID de ce Mac).
    public static func plausible(_ degres: Double) -> Bool {
        degres > 0 && degres < 130
    }

    /// `smc` : valeurs des clés de température ; `ssd` : capteur HID du SSD.
    public init(date: Date, smc: [String: Double], ssd: Double? = nil, ventilateurs: [Ventilateur] = [], charge: Double? = nil) {
        func valeurs(_ famille: Famille) -> [Double] {
            smc.filter { Famille.smc($0.key) == famille && Releve.plausible($0.value) }.map(\.value)
        }
        let processeur = valeurs(.processeur)
        self.date = date
        processeurMoyenne = processeur.isEmpty ? nil : processeur.reduce(0, +) / Double(processeur.count)
        processeurMax = processeur.max()
        let batterie = valeurs(.batterie).max()
        self.batterie = batterie
        graphique = valeurs(.graphique).max().flatMap { $0 < (batterie ?? 0) ? nil : $0 }
        self.ssd = ssd.flatMap { Releve.plausible($0) ? $0 : nil }
        self.ventilateurs = ventilateurs
        self.charge = charge
    }
}

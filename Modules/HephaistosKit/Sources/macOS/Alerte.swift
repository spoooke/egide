import Foundation

/// Réglages de l'alerte de température.
public struct ReglagesAlerte: Equatable, Sendable {
    public var active: Bool
    /// Température à partir de laquelle le Mac est jugé trop chaud.
    public var seuil: Double
    /// Secondes à passer au-dessus du seuil avant d'alerter.
    public var duree: TimeInterval

    public init(active: Bool, seuil: Double, duree: TimeInterval) {
        self.active = active
        self.seuil = seuil
        self.duree = duree
    }

    /// D'après l'essai sous charge du 12 octobre 2026 (MacBook Pro M4) : le point le plus chaud atteint 93 °C
    /// processeur à fond et 87 °C en charge graphique. 95 °C tenus 2 minutes sortent donc de l'usage normal,
    /// jeu compris.
    public static let parDefaut = ReglagesAlerte(active: true, seuil: 95, duree: 120)
    public static let seuils: ClosedRange<Double> = 70...105
    public static let durees: [TimeInterval] = [30, 60, 120, 300, 600]

    public static func texte(duree: TimeInterval) -> String {
        duree < 60 ? "\(Int(duree)) s" : "\(Int(duree / 60)) min"
    }
}

/// Réglages des alertes de mémoire et de disque.
public struct ReglagesRessources: Equatable, Sendable {
    public var memoire: Bool
    public var disque: Bool
    /// Espace libre, en Go, sous lequel le disque est jugé presque plein.
    public var seuilDisque: Double

    public init(memoire: Bool, disque: Bool, seuilDisque: Double) {
        self.memoire = memoire
        self.disque = disque
        self.seuilDisque = seuilDisque
    }

    public static let parDefaut = ReglagesRessources(memoire: true, disque: true, seuilDisque: 20)
    public static let seuilsDisque: ClosedRange<Double> = 5...100
    /// Secondes de pression élevée ou critique avant d'alerter : une pointe passagère ne compte pas.
    public static let dureeMemoire = 120.0
    /// Go à regagner au-dessus du seuil pour clore un épisode de disque presque plein.
    public static let margeDisque = 2.0
    static let giga = 1e9
}

/// Une seule alerte par épisode : elle part quand le dépassement a tenu `duree` secondes, et la suivante
/// n'est possible qu'après un retour net à la normale (`rearme`).
public struct Episode: Equatable, Sendable {
    /// Au-delà de ce silence entre deux mesures (Mac en veille), le décompte repart de zéro.
    public static let silenceMaxi = 30.0

    private var debut: Date?
    private var signalee = false
    private var derniere: Date?

    public init() {}

    /// À appeler à chaque mesure ; renvoie vrai quand il faut alerter.
    public mutating func observer(depasse: Bool, rearme: Bool, le date: Date, duree: TimeInterval) -> Bool {
        if let derniere, date.timeIntervalSince(derniere) > Self.silenceMaxi { debut = nil }
        derniere = date
        if depasse {
            let depuis = debut ?? date
            debut = depuis
            guard !signalee, date.timeIntervalSince(depuis) >= duree else { return false }
            signalee = true
            return true
        }
        debut = nil
        if rearme { signalee = false }
        return false
    }
}

/// Décide quand alerter : une seule alerte par épisode de chauffe.
/// L'alerte part quand la température est restée au-dessus du seuil pendant toute la durée réglée ; la suivante
/// n'est possible qu'une fois la température redescendue de `marge` degrés sous le seuil.
public struct Veille: Equatable, Sendable {
    /// Degrés à reperdre sous le seuil pour clore un épisode : une température qui oscille autour du seuil
    /// ne relance pas l'alerte.
    public static let marge = 5.0
    public static let silenceMaxi = Episode.silenceMaxi

    private var episode = Episode()

    public init() {}

    /// À appeler à chaque mesure ; renvoie vrai quand il faut alerter.
    public mutating func observer(_ degres: Double, le date: Date, reglages: ReglagesAlerte) -> Bool {
        guard reglages.active else {
            self = Veille()
            return false
        }
        return episode.observer(depasse: degres >= reglages.seuil, rearme: degres < reglages.seuil - Self.marge, le: date, duree: reglages.duree)
    }
}

/// Repère « normal / anormal » : ce qui fait chauffer le Mac au moment de l'alerte.
public enum Diagnostic: Equatable, Sendable {
    /// L'app utilisée en ce moment travaille fort (un jeu, un montage) : chauffe attendue.
    case premierPlan(Consommation)
    /// Une app travaille fort sans être à l'écran.
    case arrierePlan(Consommation)
    /// Aucune app ne travaille fort : la chaleur vient d'ailleurs (aérations, ventilateur, pièce chaude).
    case aucune(Consommation?)

    /// Consommation, en cœurs, à partir de laquelle une app « travaille fort ».
    public static let forte = 0.5

    /// `classement` : apps de la plus gourmande à la moins gourmande.
    public init(_ classement: [Consommation]) {
        guard let premiere = classement.first, premiere.coeurs >= Self.forte else {
            self = .aucune(classement.first)
            return
        }
        self = premiere.auPremierPlan ? .premierPlan(premiere) : .arrierePlan(premiere)
    }

    public var phrase: String {
        switch self {
        case .premierPlan(let app):
            "Normal sous forte charge : « \(app.nom) », au premier plan, utilise \(app.texte)."
        case .arrierePlan(let app):
            "À vérifier : « \(app.nom) » travaille en arrière-plan (\(app.texte))."
        case .aucune(let app?):
            "Anormal : aucune app ne travaille fort (la plus active : « \(app.nom) », \(app.texte)). Vérifier les aérations."
        case .aucune(nil):
            "Anormal : aucune app ne travaille fort. Vérifier les aérations."
        }
    }
}

/// Une alerte envoyée.
public struct Alerte: Equatable, Sendable {
    public var date: Date
    public var degres: Double
    public var reglages: ReglagesAlerte
    public var diagnostic: Diagnostic
    /// Alerte demandée par le bouton « Essayer », sans dépassement réel.
    public var essai: Bool

    public init(date: Date, degres: Double, reglages: ReglagesAlerte, diagnostic: Diagnostic, essai: Bool = false) {
        self.date = date
        self.degres = degres
        self.reglages = reglages
        self.diagnostic = diagnostic
        self.essai = essai
    }

    public var titre: String {
        (essai ? "Essai d'alerte : " : "Mac chaud : ") + HephaistosModele.texte(degres)
    }

    /// Seuil et durée dépassés, sans l'app qui chauffe.
    public var contexte: String {
        essai
            ? "L'alerte part au-dessus de \(HephaistosModele.texte(reglages.seuil)) pendant \(ReglagesAlerte.texte(duree: reglages.duree))."
            : "Au-dessus de \(HephaistosModele.texte(reglages.seuil)) depuis \(ReglagesAlerte.texte(duree: reglages.duree))."
    }

    public var message: String { contexte + " " + diagnostic.phrase }

    public var avis: Avis {
        Avis(date: date, sorte: .temperature, titre: titre, resume: contexte, detail: diagnostic.phrase)
    }
}

/// Ce qui est annoncé à l'utilisateur, quelle que soit l'alerte : notification du Mac, fenêtre, iPhone.
public struct Avis: Equatable, Sendable {
    public enum Sorte: String, Sendable {
        case temperature, memoire, disque

        /// Nom envoyé au serveur Argos (rien pour la température).
        var distante: String? {
            switch self {
            case .temperature: nil
            case .memoire: "memory"
            case .disque: "disk"
            }
        }
    }

    public var date: Date
    public var sorte: Sorte
    public var titre: String
    /// Ce qui est dépassé : seule partie relayée en notification sur l'iPhone.
    public var resume: String
    /// Les apps en cause (vide s'il n'y en a pas).
    public var detail: String

    public init(date: Date, sorte: Sorte, titre: String, resume: String, detail: String) {
        self.date = date
        self.sorte = sorte
        self.titre = titre
        self.resume = resume
        self.detail = detail
    }

    public var message: String { detail.isEmpty ? resume : resume + " " + detail }

    /// `apps` : celles qui occupent le plus de mémoire.
    public static func memoire(_ memoire: Memoire, apps: [Occupation], le date: Date) -> Avis {
        let liste = apps.map { "« \($0.nom) » (\(Taille.memoire($0.octets)))" }.joined(separator: ", ")
        return Avis(date: date, sorte: .memoire, titre: "Mémoire saturée : \(memoire.texte)",
                    resume: "Pression \(memoire.pression.texte) depuis \(ReglagesAlerte.texte(duree: ReglagesRessources.dureeMemoire)).",
                    detail: liste.isEmpty ? "" : "Les plus grosses apps : \(liste).")
    }

    /// `seuil` : espace libre, en Go, sous lequel l'alerte part.
    public static func disque(_ disque: Disque, seuil: Double, le date: Date) -> Avis {
        Avis(date: date, sorte: .disque, titre: "Disque presque plein : \(Taille.disque(disque.libre)) libres",
             resume: "Moins de \(Int(seuil)) Go libres sur \(Taille.disque(disque.total)).", detail: "")
    }
}

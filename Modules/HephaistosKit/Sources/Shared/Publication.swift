import Foundation

/// Pression sur la mémoire, telle que le système la juge (vert, orange, rouge dans le Moniteur d'activité).
public enum Pression: Int, Codable, Comparable, Sendable {
    case normale, elevee, critique

    public static func < (gauche: Pression, droite: Pression) -> Bool { gauche.rawValue < droite.rawValue }

    public var texte: String {
        switch self {
        case .normale: "normale"
        case .elevee: "élevée"
        case .critique: "critique"
        }
    }
}

/// Mémoire vive du Mac, en octets.
public struct Memoire: Codable, Equatable, Sendable {
    /// Comme « Mémoire utilisée » du Moniteur d'activité : apps, mémoire réservée par le système, mémoire compressée.
    public var utilisee: Double
    public var totale: Double
    public var pression: Pression

    public init(utilisee: Double, totale: Double, pression: Pression) {
        self.utilisee = utilisee
        self.totale = totale
        self.pression = pression
    }

    /// Part utilisée, de 0 à 1.
    public var part: Double { totale > 0 ? min(1, max(0, utilisee / totale)) : 0 }

    public var texte: String { "\(Taille.memoire(utilisee)) sur \(Taille.memoire(totale))" }

    enum CodingKeys: String, CodingKey {
        case utilisee = "used", totale = "total", pression = "pressure"
    }
}

/// Mémoire occupée par une app, ses processus auxiliaires compris.
public struct Occupation: Codable, Equatable, Identifiable, Sendable {
    public var nom: String
    public var octets: Double
    public var id: String { nom }

    public init(nom: String, octets: Double) {
        self.nom = nom
        self.octets = octets
    }

    enum CodingKeys: String, CodingKey {
        case nom = "name", octets = "bytes"
    }
}

/// Disque de démarrage du Mac, en octets.
public struct Disque: Codable, Equatable, Sendable {
    /// Espace libre comme l'annonce le Finder (ce que le système peut libérer tout seul est compté libre).
    public var libre: Double
    public var total: Double

    public init(libre: Double, total: Double) {
        self.libre = libre
        self.total = total
    }

    /// Part occupée, de 0 à 1.
    public var part: Double { total > 0 ? min(1, max(0, 1 - libre / total)) : 0 }

    public var texte: String { "\(Taille.disque(libre)) libres sur \(Taille.disque(total))" }

    enum CodingKeys: String, CodingKey {
        case libre = "free", total
    }
}

/// Puce graphique du Mac : part du temps occupée et mémoire qu'elle utilise (prise sur la mémoire vive).
public struct CarteGraphique: Codable, Equatable, Sendable {
    /// De 0 à 1.
    public var utilisation: Double
    /// En octets.
    public var memoire: Double

    public init(utilisation: Double, memoire: Double) {
        self.utilisation = utilisation
        self.memoire = memoire
    }

    public var texte: String {
        "\(utilisation.formatted(.percent.precision(.fractionLength(0)).locale(Locale(identifier: "fr_FR")))) · \(Taille.memoire(memoire))"
    }

    enum CodingKeys: String, CodingKey {
        case utilisation = "use", memoire = "memory"
    }
}

/// Écriture d'une taille en octets, avec les unités du Mac : la mémoire se compte en puissances de 2
/// (16 Go = 2³⁴ octets), le disque en puissances de 10 (comme le Finder).
public enum Taille {
    public static func memoire(_ octets: Double) -> String { texte(octets, kilo: 1024) }
    public static func disque(_ octets: Double) -> String { texte(octets, kilo: 1000) }

    static func texte(_ octets: Double, kilo: Double) -> String {
        let giga = octets / (kilo * kilo * kilo)
        if giga < 1 { return "\(Int((giga * kilo).rounded())) Mo" }
        // Une décimale sous 100 Go, aucune au-delà.
        let nombre = giga < 100 && giga.rounded() != giga ? giga.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "fr_FR"))) : "\(Int(giga.rounded()))"
        return "\(nombre) Go"
    }
}

/// Ce que le Mac envoie au serveur Argos (POST /api/temperature) : une mesure par minute, et l'alerte quand elle part.
public struct Publication: Codable, Equatable, Sendable {
    public var degres: Double
    public var ventilateur: Double
    public var ventilateurMaxi: Double
    /// Charge du processeur, de 0 à 1.
    public var charge: Double
    public var carteGraphique: CarteGraphique?
    public var memoire: Memoire?
    /// Les apps qui occupent le plus de mémoire, de la plus grosse à la plus petite.
    public var appsMemoire: [Occupation]?
    public var disque: Disque?
    public var alerte: AlerteDistante?

    public init(degres: Double, ventilateur: Double, ventilateurMaxi: Double, charge: Double, carteGraphique: CarteGraphique? = nil,
                memoire: Memoire? = nil, appsMemoire: [Occupation]? = nil, disque: Disque? = nil, alerte: AlerteDistante? = nil) {
        self.degres = degres
        self.ventilateur = ventilateur
        self.ventilateurMaxi = ventilateurMaxi
        self.charge = charge
        self.carteGraphique = carteGraphique
        self.memoire = memoire
        self.appsMemoire = appsMemoire
        self.disque = disque
        self.alerte = alerte
    }

    enum CodingKeys: String, CodingKey {
        case degres = "degrees", ventilateur = "fanRpm", ventilateurMaxi = "fanMax", charge = "load", carteGraphique = "gpu"
        case memoire = "memory", appsMemoire = "memoryApps", disque = "disk", alerte = "alert"
    }
}

public struct AlerteDistante: Codable, Equatable, Sendable {
    /// Heure de réception par le serveur (absente à l'envoi).
    public var date: Date?
    public var degres: Double
    public var titre: String
    /// Seuil et durée dépassés : seule partie relayée en notification sur l'iPhone.
    public var resume: String
    /// Les apps en cause : visible dans Égide seulement.
    public var detail: String
    public var essai: Bool?
    /// « memory » ou « disk » ; absent pour une alerte de température.
    public var sorte: String?

    public init(degres: Double, titre: String, resume: String, detail: String, essai: Bool, sorte: String? = nil) {
        self.degres = degres
        self.titre = titre
        self.resume = resume
        self.detail = detail
        self.essai = essai ? true : nil
        self.sorte = sorte
    }

    enum CodingKeys: String, CodingKey {
        case date = "at", degres = "degrees", titre = "title", resume = "summary", detail, essai = "test", sorte = "kind"
    }
}

/// Ce que lit l'iPhone (GET /api/temperature) : dernière mesure, courbe de la dernière heure, dernière alerte.
public struct EtatDistant: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Identifiable, Sendable {
        public var date: Date
        public var degres: Double
        public var id: Date { date }

        enum CodingKeys: String, CodingKey {
            case date = "at", degres = "degrees"
        }
    }

    /// nil tant que le Mac n'a rien envoyé depuis le démarrage du serveur.
    public var date: Date?
    public var degres: Double
    public var ventilateur: Double
    public var ventilateurMaxi: Double
    public var charge: Double
    public var carteGraphique: CarteGraphique?
    public var memoire: Memoire?
    public var appsMemoire: [Occupation]?
    public var disque: Disque?
    public var historique: [Point]
    public var alerte: AlerteDistante?

    enum CodingKeys: String, CodingKey {
        case date = "at", degres = "degrees", ventilateur = "fanRpm", ventilateurMaxi = "fanMax", charge = "load", carteGraphique = "gpu"
        case memoire = "memory", appsMemoire = "memoryApps", disque = "disk", historique = "history", alerte = "alert"
    }

    /// Au-delà de ce silence, le Mac est en veille ou éteint (il envoie une mesure par minute).
    public static let silenceMaxi = 180.0

    public init(json: Data) throws {
        let decodeur = JSONDecoder()
        decodeur.dateDecodingStrategy = .iso8601
        self = try decodeur.decode(EtatDistant.self, from: json)
    }

    public static func texte(_ degres: Double) -> String { "\(Int(degres.rounded()))°" }

    public func muet(a maintenant: Date = .now) -> Bool {
        date.map { maintenant.timeIntervalSince($0) > Self.silenceMaxi } ?? true
    }

    /// « il y a 2 min », ou l'heure de la dernière mesure quand le Mac ne répond plus.
    public func fraicheur(a maintenant: Date = .now) -> String? {
        guard let date else { return nil }
        if muet(a: maintenant) {
            return "Mac en veille ou éteint · dernière mesure \(date.formatted(.relative(presentation: .named).locale(Locale(identifier: "fr_FR"))))"
        }
        let minutes = Int(maintenant.timeIntervalSince(date) / 60)
        return minutes < 1 ? "à l'instant" : "il y a \(minutes) min"
    }

    /// Ligne de l'Accueil d'Égide (nil sans mesure).
    public func resume(a maintenant: Date = .now) -> String? {
        fraicheur(a: maintenant).map { muet(a: maintenant) ? $0 : "\(Self.texte(degres)) · \($0)" }
    }
}

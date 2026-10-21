import Foundation

/// Ce qu'on peut demander à distance (depuis Égide sur l'iPhone) : un dépôt public par un lien https, ou un paquet
/// PyPI. Jamais un chemin : un fichier du Mac ne part à l'IA qu'après un accord donné sur le Mac.
/// Le même contrôle est fait trois fois : sur l'iPhone avant l'envoi, par le serveur Argos, puis par le relais
/// du Mac avant de lancer quoi que ce soit.
public enum CibleDistante: Equatable, Sendable {
    /// `hote` : seul domaine contacté par le Mac pour récupérer le dépôt.
    case lien(String, hote: String)
    case paquet(String)

    public enum Refus: Error, Equatable, CustomStringConvertible, Sendable {
        case vide, forme, pasHttps, identifiants, hote, tropLong

        public var description: String {
            switch self {
            case .vide: "Aucun lien."
            case .forme: "Ni un lien https://, ni un paquet « pypi:nom »."
            case .pasHttps: "Seul un lien https:// est accepté."
            case .identifiants: "Le lien contient des identifiants ou un port."
            case .hote: "Le lien doit pointer vers un site public (pas une adresse IP ni une machine du réseau local)."
            case .tropLong: "Lien trop long."
            }
        }
    }

    public static let longueurMax = 300
    static let suffixesLocaux = [".local", ".localhost", ".internal", ".lan", ".home", ".ts.net"]

    /// Lit un texte saisi, collé ou partagé. Le lien est ramené à l'adresse du dépôt : sans paramètres ni ancre,
    /// et, sur GitHub et GitLab, sans la page ouverte (`/tree/main/…`, `/-/blob/…`).
    public init(_ texte: String) throws(Refus) {
        let t = texte.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw .vide }
        guard t.count <= 2000, !t.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }) else { throw .forme }
        if t.lowercased().hasPrefix("pypi:") {
            self = .paquet(try Self.paquet(String(t.dropFirst(5))))
            return
        }
        guard var parties = URLComponents(string: t), let schema = parties.scheme?.lowercased() else { throw .forme }
        guard schema == "https" else { throw schema == "http" ? .pasHttps : .forme }
        guard parties.user == nil, parties.password == nil, parties.port == nil else { throw .identifiants }
        var hote = (parties.host ?? "").lowercased()
        // Nom en ASCII avec au moins un point : ni adresse IP, ni nom local, ni lettres ressemblantes d'un autre alphabet.
        guard hote.contains("."), !hote.hasSuffix("."), !hote.hasPrefix("."), hote.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              hote.contains(where: \.isLetter), !Self.suffixesLocaux.contains(where: hote.hasSuffix) else { throw .hote }
        if hote == "www.github.com" { hote = "github.com" }
        var morceaux = parties.percentEncodedPath.split(separator: "/").map(String.init)
        // Page d'un paquet sur pypi.org : c'est le paquet qu'on audite.
        if hote == "pypi.org", morceaux.count >= 2, morceaux[0] == "project" {
            self = .paquet(try Self.paquet(morceaux[1]))
            return
        }
        if hote == "github.com", morceaux.count > 2 { morceaux = Array(morceaux.prefix(2)) }
        if hote == "gitlab.com", let i = morceaux.firstIndex(of: "-") { morceaux = Array(morceaux.prefix(i)) }
        guard !morceaux.contains(".."), !(morceaux.first ?? "").hasPrefix("-") else { throw .forme }
        parties.scheme = "https"
        parties.host = hote
        parties.percentEncodedPath = morceaux.isEmpty ? "" : "/" + morceaux.joined(separator: "/")
        parties.query = nil
        parties.fragment = nil
        guard let lien = parties.string, lien.count <= Self.longueurMax else { throw .tropLong }
        self = .lien(lien, hote: hote)
    }

    private static func paquet(_ nom: String) throws(Refus) -> String {
        let permis = nom.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        guard !nom.isEmpty, nom.count <= 100, permis, nom.first!.isLetter || nom.first!.isNumber, nom.last!.isLetter || nom.last!.isNumber else { throw .forme }
        return nom
    }

    /// La cible telle que `Audit.auditer` et le serveur l'attendent.
    public var cible: String {
        switch self {
        case .lien(let lien, _): lien
        case .paquet(let nom): "pypi:\(nom)"
        }
    }

    /// Domaines que le Mac contactera pour récupérer le code.
    public var domaines: [String] {
        switch self {
        case .lien(_, let hote): [hote]
        case .paquet: ["pypi.org", "files.pythonhosted.org"]
        }
    }
}

/// Un audit demandé à distance, tel que le serveur Argos le garde (routes `/api/cerbere/…`).
public struct AuditDistant: Codable, Equatable, Identifiable, Sendable {
    public enum Etat: String, Codable, Sendable {
        case attente = "waiting", enCours = "running", termine = "done", echec = "failed", annule = "cancelled"
    }

    public var id: String
    public var cible: String
    public var etat: Etat
    public var demande: Date
    public var fin: Date?
    /// Avancement, tant que l'audit tourne.
    public var etape: String?
    public var verdict: Verdict?
    public var erreur: String?
    public var annulationDemandee: Bool?
    /// Présent seulement à la lecture d'un audit terminé.
    public var rapport: Rapport?

    enum CodingKeys: String, CodingKey {
        case id, cible = "target", etat = "state", demande = "requestedAt", fin = "endedAt", etape = "step"
        case verdict, erreur = "error", annulationDemandee = "cancelAsked", rapport = "report"
    }

    public var actif: Bool { etat == .attente || etat == .enCours }

    /// « auteur/dépôt », ou le nom du paquet.
    public var nomCourt: String {
        if cible.hasPrefix("pypi:") { return String(cible.dropFirst(5)) }
        let morceaux = cible.split(separator: "/").dropFirst(2).map(String.init)
        return morceaux.isEmpty ? cible : morceaux.suffix(2).joined(separator: "/")
    }
}

/// Réponse de `GET /api/cerbere/audits` : les audits, du plus récent au plus ancien.
public struct ListeDistante: Codable, Equatable, Sendable {
    /// Le relais du Mac a demandé du travail il y a moins de 30 secondes.
    public var relaisActif: Bool
    public var audits: [AuditDistant]

    enum CodingKeys: String, CodingKey {
        case relaisActif = "worker", audits
    }
}

public enum Distant {
    public static func decoder<T: Decodable>(_ type: T.Type, _ json: Data) throws -> T {
        let decodeur = JSONDecoder()
        decodeur.dateDecodingStrategy = .iso8601
        return try decodeur.decode(type, from: json)
    }
}

extension String {
    /// Texte venu du code audité (nom de fichier, extrait, domaine), prêt à être affiché tel quel avec
    /// `Text(verbatim:)` : les caractères de contrôle, invisibles ou qui inversent le sens de lecture sont
    /// remplacés, pour qu'une ligne ne puisse pas se déguiser à l'écran.
    public var montrable: String {
        var vue = String.UnicodeScalarView()
        for s in unicodeScalars {
            let v = s.value
            let cache = (v < 32 && s != "\n" && s != "\t") || (127...159).contains(v) || (0x200B...0x200F).contains(v)
                || (0x202A...0x202E).contains(v) || (0x2060...0x2069).contains(v) || v == 0xFEFF
            vue.append(cache ? "\u{FFFD}" : s)
        }
        return String(vue)
    }
}

import Foundation

/// Rapport d'audit de Cerbère (format décrit dans docs/cerbere.md). `rapport.json` est la source,
/// `rapport.md` en est le rendu lisible.
public struct Rapport: Codable, Equatable, Sendable {
    public var version = 1
    public var cible: Cible
    public var date: Date
    public var verdict: Verdict
    public var resume: String
    public var constats: [Constat]
    public var reseau: Reseau
    public var nonAnalyse: [NonAnalyse]
    public var couches: Couches
    public var fichiersAnalyses: Int
    /// Bilan de la lecture par IA (absent si elle n'a pas eu lieu).
    public var ia: BilanIA? = nil
    /// Explication en mots simples, demandée après l'audit (absente tant qu'on ne l'a pas demandée).
    public var neophyte: Explication? = nil

    enum CodingKeys: String, CodingKey {
        case version, cible, date, verdict, resume, constats, reseau, couches, ia, neophyte
        case nonAnalyse = "non_analyse"
        case fichiersAnalyses = "fichiers_analyses"
    }
}

public struct Cible: Codable, Equatable, Sendable {
    public enum Sorte: String, Codable, Sendable { case depot, app, fichier }
    public var type: Sorte
    public var source: String
    public var commit: String?
    public var empreinte: String?
}

public enum Verdict: String, Codable, Sendable {
    case nePasInstaller = "ne_pas_installer"
    case risque
    case rienDeGrave = "rien_de_grave"
    case incomplet

    public var titre: String {
        switch self {
        case .nePasInstaller: "Ne pas installer"
        case .risque: "Risqué"
        case .rienDeGrave: "Rien de grave trouvé"
        case .incomplet: "Analyse incomplète"
        }
    }
}

public enum Gravite: String, Codable, Sendable, CaseIterable, Comparable {
    case critique, elevee, moyenne, faible, info

    public var titre: String {
        switch self {
        case .critique: "Critique"
        case .elevee: "Élevée"
        case .moyenne: "Moyenne"
        case .faible: "Faible"
        case .info: "Info"
        }
    }

    /// La plus grave en premier.
    public static func < (a: Gravite, b: Gravite) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    /// Un cran en dessous (documentation, exemples : le motif est là, mais ce n'est pas du code lancé).
    var attenuee: Gravite {
        let i = Gravite.allCases.firstIndex(of: self)!
        return Gravite.allCases[min(i + 1, Gravite.allCases.count - 1)]
    }
}

public enum Statut: String, Codable, Sendable {
    /// Le comportement se lit directement dans le code cité.
    case confirme
    /// Indice qui demande une vérification.
    case suspect
}

public enum Categorie: String, Codable, Sendable, CaseIterable {
    case reseau, obfuscation, secrets, persistance, installation, dependances, manipulation, autre

    public var titre: String {
        switch self {
        case .reseau: "Réseau"
        case .obfuscation: "Code caché ou téléchargé"
        case .secrets: "Accès aux secrets"
        case .persistance: "Persistance"
        case .installation: "Scripts d'installation"
        case .dependances: "Dépendances"
        case .manipulation: "Tentative de manipulation"
        case .autre: "Autre"
        }
    }
}

public struct Constat: Codable, Equatable, Sendable {
    public enum Origine: String, Codable, Sendable { case regle, ia }
    public var id: String
    public var gravite: Gravite
    public var statut: Statut
    public var categorie: Categorie
    public var titre: String
    public var fichier: String
    /// Première et dernière ligne (identiques pour une seule ligne) ; vide si le constat porte sur le fichier entier.
    public var lignes: [Int]
    public var extrait: String
    public var explication: String
    public var origine: Origine
    /// Identifiant de la règle qui a produit le constat (absent pour l'IA).
    public var regle: String?
    /// Avis de la lecture par IA sur un constat des règles (absent si l'IA ne l'a pas lu).
    public var avisIA: AvisIA? = nil
    /// Raison donnée par l'IA pour son avis.
    public var noteIA: String? = nil
    /// Vérification ciblée demandée après l'audit (« check-up » d'un constat).
    public var verification: Verification? = nil

    enum CodingKeys: String, CodingKey {
        case id, gravite, statut, categorie, titre, fichier, lignes, extrait, explication, origine, regle, verification
        case avisIA = "avis_ia"
        case noteIA = "note_ia"
    }

    /// Écarté par la lecture par IA : gardé dans le rapport, mais ne pèse plus sur le verdict.
    public var ecarte: Bool { avisIA == .fauxPositif }
}

/// Résultat d'une vérification ciblée : l'IA relit le passage avec plus de contexte et tranche.
/// Ce qu'elle conclut n'agit sur le constat que dans les limites fixées par le code (voir `Verifications`).
public struct Verification: Codable, Equatable, Sendable {
    public enum Conclusion: String, Codable, Sendable {
        case fauxPositif = "faux_positif", normal, aSurveiller = "a_surveiller", grave

        public var titre: String {
            switch self {
            case .fauxPositif: "Faux positif"
            case .normal: "Normal"
            case .aSurveiller: "À surveiller"
            case .grave: "Grave"
            }
        }
    }

    public var conclusion: Conclusion
    /// En mots simples : ce que fait vraiment ce passage et pourquoi c'est (ou non) un problème.
    public var explication: String
    /// Ce que le code a fait de la conclusion (écarté, confirmé, ou refusé et pourquoi), et les réserves (version différente…).
    public var effet: String
    public var modele: String
    public var date: Date

    public init(conclusion: Conclusion, explication: String, effet: String, modele: String, date: Date) {
        self.conclusion = conclusion
        self.explication = explication
        self.effet = effet
        self.modele = modele
        self.date = date
    }
}

public enum AvisIA: String, Codable, Sendable {
    case confirme
    case fauxPositif = "faux_positif"
}

/// Ce que la lecture par IA a couvert.
public struct BilanIA: Codable, Equatable, Sendable {
    public var modele: String
    /// Fichiers lus en entier.
    public var fichiersLus: Int
    /// Gros fichiers dont seuls les passages sensibles ont été lus.
    public var fichiersEnPartie: Int
    public var fichiersLisibles: Int
    public var lots: Int
    public var lotsEchoues: Int
    /// Constats de l'IA retirés parce que l'extrait cité n'existe pas à l'endroit annoncé.
    public var citationsIntrouvables: Int
    /// Constats de l'IA retirés ou baissés à la relecture.
    public var retiresALaRelecture: Int
    /// Secrets masqués avant l'envoi.
    public var secretsMasques: Int
    /// Une tentative de manipulation a été relevée : l'IA n'a rien pu écarter.
    public var manipulation: Bool

    enum CodingKeys: String, CodingKey {
        case modele, lots, manipulation
        case fichiersLus = "fichiers_lus"
        case fichiersEnPartie = "fichiers_en_partie"
        case fichiersLisibles = "fichiers_lisibles"
        case lotsEchoues = "lots_echoues"
        case citationsIntrouvables = "citations_introuvables"
        case retiresALaRelecture = "retires_a_la_relecture"
        case secretsMasques = "secrets_masques"
    }
}

/// Le rapport redit pour quelqu'un qui n'y connaît rien, par l'IA, à partir du rapport seul (jamais du code).
/// Le verdict n'en fait pas partie : il reste celui calculé par le code, affiché au-dessus.
public struct Explication: Codable, Equatable, Sendable {
    /// Deux à quatre phrases : ce qu'est le logiciel et ce que l'audit en dit.
    public var enBref: String
    /// Ce qu'il faut savoir, une idée par ligne.
    public var aSavoir: [String]
    /// Que faire, concrètement.
    public var queFaire: [String]
    public var modele: String
    public var date: Date

    public init(enBref: String, aSavoir: [String], queFaire: [String], modele: String, date: Date) {
        self.enBref = enBref
        self.aSavoir = aSavoir
        self.queFaire = queFaire
        self.modele = modele
        self.date = date
    }

    enum CodingKeys: String, CodingKey {
        case modele, date
        case enBref = "en_bref"
        case aSavoir = "a_savoir"
        case queFaire = "que_faire"
    }
}

public struct Reseau: Codable, Equatable, Sendable {
    public struct Hote: Codable, Equatable, Sendable {
        public var nom: String
        /// Fichiers où il apparaît (les cinq premiers).
        public var fichiers: [String]
        public var occurrences: Int
    }
    public var domaines: [Hote] = []
    public var adresses: [Hote] = []
}

public struct NonAnalyse: Codable, Equatable, Sendable {
    public var fichier: String
    public var raison: String
}

public struct Couches: Codable, Equatable, Sendable {
    public var regles: Bool
    public var ia: Bool
    /// Vérifications faites hors du Mac, avec l'accord donné pour cet audit (absentes sinon).
    public var gatekeeper: Bool? = nil
    public var reputation: Bool? = nil
    /// Règles YARA appliquées (absent dans les rapports d'avant la phase 6).
    public var yara: Bool? = nil
    /// Dépendances comparées à la base OSV (osv.dev).
    public var vulnerabilites: Bool? = nil
}

extension Rapport {
    /// Verdict tiré des constats (règle écrite dans docs/cerbere.md).
    public static func verdict(constats: [Constat], fichiersAnalyses: Int) -> Verdict {
        func existe(_ g: Gravite, _ s: Statut) -> Bool { constats.contains { $0.gravite == g && $0.statut == s && !$0.ecarte } }
        if existe(.critique, .confirme) { return .nePasInstaller }
        if existe(.elevee, .confirme) || existe(.critique, .suspect) { return .risque }
        if fichiersAnalyses == 0 { return .incomplet }
        return .rienDeGrave
    }

    /// Constats triés : écartés par l'IA à la fin, puis gravité décroissante, confirmés avant suspects, fichier et ligne.
    public var constatsTries: [Constat] {
        constats.sorted {
            if $0.ecarte != $1.ecarte { return !$0.ecarte }
            if $0.gravite != $1.gravite { return $0.gravite < $1.gravite }
            if $0.statut != $1.statut { return $0.statut == .confirme }
            if $0.fichier != $1.fichier { return $0.fichier < $1.fichier }
            return ($0.lignes.first ?? 0) < ($1.lignes.first ?? 0)
        }
    }

    public func json() throws -> Data {
        let encodeur = JSONEncoder()
        encodeur.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encodeur.dateEncodingStrategy = .iso8601
        return try encodeur.encode(self)
    }

    public init(json: Data) throws {
        let decodeur = JSONDecoder()
        decodeur.dateDecodingStrategy = .iso8601
        self = try decodeur.decode(Rapport.self, from: json)
    }

    /// Rendu lisible. Les extraits viennent du code audité : ils sont mis en bloc de code, jamais interprétés.
    public func markdown() -> String {
        // Les noms de fichiers viennent du dépôt audité : pas d'accent grave ni de saut de ligne dans le rendu.
        func nom(_ s: String) -> String { String(s.map { $0 == "`" || $0.isNewline ? "?" : $0 }) }
        var t = "# Cerbère — \(verdict.titre)\n\n"
        t += "- Cible : `\(nom(cible.source))`\n"
        if let commit = cible.commit { t += "- Commit : `\(commit)`\n" }
        if let empreinte = cible.empreinte { t += "- Empreinte : `\(empreinte)`\n" }
        t += "- Date : \(date.formatted(.iso8601))\n"
        t += "- Couches : règles automatiques\(couches.yara == true ? " et YARA" : "")\(couches.ia ? " + lecture par IA" : " seules (pas de lecture par IA)")\n"
        if couches.gatekeeper == true || couches.reputation == true || couches.vulnerabilites == true {
            t += "- Vérifications en ligne : \([couches.gatekeeper == true ? "Gatekeeper (Apple)" : nil, couches.reputation == true ? "réputation de l'empreinte (VirusTotal)" : nil, couches.vulnerabilites == true ? "vulnérabilités connues des dépendances (OSV, noms et versions seulement)" : nil].compactMap { $0 }.joined(separator: ", "))\n"
        }
        t += "- Fichiers analysés : \(fichiersAnalyses)\n"
        if let ia {
            t += "- Lecture par IA (\(nom(ia.modele))) : \(ia.fichiersLus) fichiers lus en entier\(ia.fichiersEnPartie > 0 ? ", \(ia.fichiersEnPartie) en partie" : "") sur \(ia.fichiersLisibles)"
            if ia.secretsMasques > 0 { t += ", \(ia.secretsMasques) secret\(ia.secretsMasques > 1 ? "s" : "") masqué\(ia.secretsMasques > 1 ? "s" : "") avant l'envoi" }
            t += "\n"
        }
        t += "\n"
        t += "\(resume)\n\n"
        t += "> Un audit statique baisse le risque, il ne prouve pas qu'un logiciel est sain.\n\n"
        if let n = neophyte {
            // Texte de l'IA : une ligne par idée, sans rien que le Markdown interpréterait comme un lien.
            func simple(_ s: String) -> String { nom(s).replacingOccurrences(of: "](", with: "] (") }
            t += "## Expliqué simplement\n\n\(simple(n.enBref))\n\n"
            if !n.aSavoir.isEmpty { t += "**À savoir**\n\n" + n.aSavoir.map { "- \(simple($0))\n" }.joined() + "\n" }
            if !n.queFaire.isEmpty { t += "**Que faire**\n\n" + n.queFaire.map { "- \(simple($0))\n" }.joined() + "\n" }
        }

        let tries = constatsTries
        func lieu(_ c: Constat) -> String {
            let fichier = nom(c.fichier)
            return c.lignes.isEmpty ? fichier
                : c.lignes.first == c.lignes.last ? "\(fichier):\(c.lignes[0])" : "\(fichier):\(c.lignes[0])-\(c.lignes.last!)"
        }
        for gravite in Gravite.allCases {
            let lot = tries.filter { $0.gravite == gravite && !$0.ecarte }
            guard !lot.isEmpty else { continue }
            t += "## \(gravite.titre) (\(lot.count))\n\n"
            for c in lot {
                t += "### \(c.id) · \(c.titre)\n\n"
                t += "- \(c.statut == .confirme ? (c.gravite <= .elevee ? "**Vu dans le code**" : "Vu dans le code") : "Suspect") · \(c.categorie.titre) · `\(lieu(c))` · \(c.origine == .ia ? "lecture par IA" : "règle automatique")\n"
                t += "- \(c.explication)\n"
                if let note = c.noteIA { t += "- Lecture par IA : \(note)\n" }
                if let v = c.verification { t += "- Vérification ciblée : **\(v.conclusion.titre)** — \(v.explication) (\(v.effet))\n" }
                t += "\n"
                if !c.extrait.isEmpty { t += "```\n\(c.extrait.replacingOccurrences(of: "```", with: "ʼʼʼ"))\n```\n\n" }
            }
        }
        if tries.isEmpty { t += "Aucun constat.\n\n" }
        let ecartes = tries.filter(\.ecarte)
        if !ecartes.isEmpty {
            t += "## Écartés par la lecture par IA (\(ecartes.count))\n\nIndices des règles automatiques que la lecture du code a jugés sans danger. Ils ne pèsent pas sur le verdict.\n\n"
            for c in ecartes { t += "- \(c.id) · \(c.titre) · `\(lieu(c))` — \(c.noteIA ?? "")\n" }
            t += "\n"
        }

        if !reseau.domaines.isEmpty || !reseau.adresses.isEmpty {
            t += "## Domaines et adresses cités dans le code\n\n"
            for h in reseau.adresses + reseau.domaines {
                t += "- `\(h.nom)` — \(h.occurrences) fois (\(h.fichiers.map(nom).joined(separator: ", ")))\n"
            }
            t += "\n"
        }
        if !nonAnalyse.isEmpty {
            t += "## Non analysé (\(nonAnalyse.count))\n\n"
            for n in nonAnalyse.prefix(200) { t += "- `\(nom(n.fichier))` — \(n.raison)\n" }
            if nonAnalyse.count > 200 { t += "- … et \(nonAnalyse.count - 200) autres\n" }
        }
        return t
    }
}

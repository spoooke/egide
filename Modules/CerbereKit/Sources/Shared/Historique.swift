import Foundation

/// Un audit gardé sur le disque : son dossier (`rapport.json`, `rapport.md`) et le rapport relu.
public struct AuditGarde: Identifiable, Equatable, Sendable {
    public var dossier: URL
    public var rapport: Rapport
    public var id: String { dossier.path }

    public init(dossier: URL, rapport: Rapport) {
        self.dossier = dossier
        self.rapport = rapport
    }
}

/// Dossier des rapports : un sous-dossier par audit.
public enum Historique {
    public static var dossier: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Cerbere/rapports")
    }

    /// Au-delà, un `rapport.json` n'est pas relu (un rapport réel fait quelques centaines de Ko).
    static let tailleMax = 50_000_000

    /// Tous les audits lisibles, le plus récent d'abord. Un dossier sans `rapport.json` lisible est ignoré.
    public static func lire(dans racine: URL = dossier) -> [AuditGarde] {
        let fm = FileManager.default
        let dossiers = (try? fm.contentsOfDirectory(at: racine, includingPropertiesForKeys: nil)) ?? []
        return dossiers.compactMap { d -> AuditGarde? in
            let fichier = d.appending(path: "rapport.json")
            guard let taille = try? fm.attributesOfItem(atPath: fichier.path)[.size] as? Int, taille <= tailleMax,
                  let donnees = try? Data(contentsOf: fichier), let rapport = try? Rapport(json: donnees) else { return nil }
            return AuditGarde(dossier: d, rapport: rapport)
        }
        .sorted { ($0.rapport.date, $0.dossier.path) > ($1.rapport.date, $1.dossier.path) }
    }

    /// Dossier où ranger un nouvel audit : `<horodatage>-<nom de la cible>`, jamais un dossier qui existe déjà.
    public static func nouveauDossier(cible: String, date: Date, dans racine: URL = dossier) -> URL {
        let nom = cible.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: ".git", with: "").replacingOccurrences(of: ":", with: "-") ?? "audit"
        let horodatage = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let base = "\(horodatage)-\(nom.filter { $0.isLetter || $0.isNumber || "-_.".contains($0) })"
        var dossier = racine.appending(path: base), n = 2
        while FileManager.default.fileExists(atPath: dossier.path) {
            dossier = racine.appending(path: "\(base)-\(n)")
            n += 1
        }
        return dossier
    }
}

extension Rapport {
    /// Ce qui désigne la même cible d'un audit à l'autre : lien sans « .git » ni barre finale, paquet PyPI sans
    /// sa version, chemin d'un dossier ou d'une archive.
    public var cleCible: String {
        let source = cible.source
        if source.hasPrefix("pypi:") { return String(source.prefix { $0 != " " }).lowercased() }
        guard source.contains("://") else { return source }
        var lien = source.lowercased()
        while lien.hasSuffix("/") { lien.removeLast() }
        if lien.hasSuffix(".git") { lien.removeLast(4) }
        return lien
    }

    /// Nom court pour une liste : « auteur/dépôt », « paquet version », nom du dossier.
    public var nomCourt: String {
        let source = cible.source
        if source.hasPrefix("pypi:") { return String(source.dropFirst(5).prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces) }
        let morceaux = cleCible.split(separator: "/").map(String.init)
        guard source.contains("://") else { return morceaux.last ?? source }
        return morceaux.dropFirst(2).suffix(2).joined(separator: "/").isEmpty ? (morceaux.last ?? source) : morceaux.dropFirst(2).suffix(2).joined(separator: "/")
    }
}

/// Ce qui a changé entre deux audits de la même cible (deux versions d'un dépôt, par exemple).
public struct Comparaison: Equatable, Sendable {
    public var verdictAvant: Verdict
    public var verdictApres: Verdict
    /// Constats du nouvel audit absents de l'ancien, dans l'ordre du rapport.
    public var apparus: [Constat]
    /// Constats de l'ancien audit absents du nouveau.
    public var disparus: [Constat]
    public var inchanges: Int
    /// Domaines et adresses cités par le code seulement dans le nouvel audit, puis seulement dans l'ancien.
    public var nouveauxDomaines: [Reseau.Hote]
    public var domainesDisparus: [Reseau.Hote]

    public var verdictChange: Bool { verdictAvant != verdictApres }
    public var rienNeChange: Bool { !verdictChange && apparus.isEmpty && disparus.isEmpty && nouveauxDomaines.isEmpty && domainesDisparus.isEmpty }

    /// Les numéros de ligne et les identifiants bougent d'une version à l'autre : un constat est reconnu par sa
    /// règle (ou sa catégorie pour l'IA), son fichier et le texte cité. Les constats écartés par l'IA ne comptent pas.
    static func cle(_ c: Constat) -> String {
        let extrait = c.extrait.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return "\(c.regle ?? "ia")|\(c.categorie.rawValue)|\(c.fichier)|\(extrait)"
    }

    public init(ancien: Rapport, nouveau: Rapport) {
        verdictAvant = ancien.verdict
        verdictApres = nouveau.verdict
        func seulement(dans a: Rapport, pasDans b: Rapport) -> [Constat] {
            var restants = Dictionary(b.constats.filter { !$0.ecarte }.map { (Self.cle($0), 1) }, uniquingKeysWith: +)
            return a.constatsTries.filter { c in
                guard !c.ecarte else { return false }
                let cle = Self.cle(c)
                guard let n = restants[cle], n > 0 else { return true }
                restants[cle] = n - 1
                return false
            }
        }
        apparus = seulement(dans: nouveau, pasDans: ancien)
        disparus = seulement(dans: ancien, pasDans: nouveau)
        inchanges = nouveau.constats.filter { !$0.ecarte }.count - apparus.count
        func hotes(_ r: Rapport) -> [Reseau.Hote] { r.reseau.adresses + r.reseau.domaines }
        let avant = Set(hotes(ancien).map { $0.nom.lowercased() }), apres = Set(hotes(nouveau).map { $0.nom.lowercased() })
        nouveauxDomaines = hotes(nouveau).filter { !avant.contains($0.nom.lowercased()) }
        domainesDisparus = hotes(ancien).filter { !apres.contains($0.nom.lowercased()) }
    }
}

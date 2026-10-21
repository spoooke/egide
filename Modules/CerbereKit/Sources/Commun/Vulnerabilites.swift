import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Vulnérabilités connues des dépendances, d'après la base OSV (`api.osv.dev`, domaine validé le 2026-10-14).
/// Seuls l'écosystème, le nom et la version de chaque dépendance partent : ni code, ni chemin, ni nom du projet.
/// Sans demander pour un dépôt public ou un paquet PyPI (ces dépendances sont déjà publiques) ; après accord, à
/// chaque audit, pour un élément du Mac. OSV recense aussi les paquets malveillants connus (identifiants `MAL-`).
public struct Vulnerabilites: Sendable {
    public static let domaine = "api.osv.dev"
    /// Questions par envoi groupé (limite de l'API).
    static let parEnvoi = 1000
    /// Fiches détaillées demandées au plus par audit.
    static let fichesMax = 200

    public enum Erreur: Error, CustomStringConvertible, Equatable {
        case reponse(Int), reseau(String), illisible

        public var description: String {
            switch self {
            case .reponse(let code): "réponse \(code) de \(Vulnerabilites.domaine)"
            case .reseau(let detail): "pas de réponse de \(Vulnerabilites.domaine) (\(detail))"
            case .illisible: "réponse illisible de \(Vulnerabilites.domaine)"
            }
        }
    }

    struct Fiche: Sendable {
        let id: String
        let resume: String
        let alias: [String]
        /// CRITICAL, HIGH, MODERATE, LOW (base GitHub), vide si inconnue.
        let gravite: String
        let corrigee: [String]
        /// Base des paquets malveillants (`MAL-`), ou avis GitHub de logiciel malveillant, reconnu au début de son
        /// intitulé (« Malicious code in … ») : une faille décrite comme « permet d'exécuter du code malveillant »
        /// n'est pas un paquet malveillant.
        var malveillant: Bool {
            id.hasPrefix("MAL-") || ["malicious code in", "malicious package", "malware in"].contains { resume.lowercased().hasPrefix($0) }
        }
    }

    typealias Transport = @Sendable (URLRequest, Annulation?) throws -> (code: Int, donnees: Data)
    let transport: Transport

    public init() { self.init(transport: Vulnerabilites.envoyer) }
    init(transport: @escaping Transport) { self.transport = transport }

    /// Ce qui part, exactement : `{"queries":[{"package":{"ecosystem","name"},"version"}…]}`.
    static func corps(_ deps: ArraySlice<Dependance>) -> Data {
        let questions = deps.map { ["package": ["ecosystem": $0.ecosysteme, "name": $0.nom], "version": $0.version] }
        return (try? JSONSerialization.data(withJSONObject: ["queries": questions], options: [.sortedKeys])) ?? Data()
    }

    /// Identifiants des failles connues, dépendance par dépendance (même ordre).
    func chercher(_ deps: [Dependance], annulation: Annulation? = nil) throws -> [[String]] {
        var resultats: [[String]] = []
        for debut in stride(from: 0, to: deps.count, by: Self.parEnvoi) {
            try annulation?.verifier()
            let lot = deps[debut..<min(debut + Self.parEnvoi, deps.count)]
            var requete = URLRequest(url: URL(string: "https://\(Self.domaine)/v1/querybatch")!)
            requete.httpMethod = "POST"
            requete.httpBody = Self.corps(lot)
            requete.setValue("application/json", forHTTPHeaderField: "Content-Type")
            requete.setValue("cerbere-audit", forHTTPHeaderField: "User-Agent")
            let (code, donnees) = try transport(requete, annulation)
            guard code == 200 else { throw Erreur.reponse(code) }
            guard let liste = ((try? JSONSerialization.jsonObject(with: donnees)) as? [String: Any])?["results"] as? [[String: Any]], liste.count == lot.count else { throw Erreur.illisible }
            resultats += liste.map { r in ((r["vulns"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.filter(Self.identifiantValide) }
        }
        return resultats
    }

    static func identifiantValide(_ id: String) -> Bool {
        id.count <= 64 && id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#, options: .regularExpression) != nil
    }

    func fiche(_ id: String, annulation: Annulation?) throws -> Fiche {
        var requete = URLRequest(url: URL(string: "https://\(Self.domaine)/v1/vulns/\(id)")!)
        requete.setValue("cerbere-audit", forHTTPHeaderField: "User-Agent")
        let (code, donnees) = try transport(requete, annulation)
        guard code == 200, let v = (try? JSONSerialization.jsonObject(with: donnees)) as? [String: Any] else { throw code == 200 ? Erreur.illisible : Erreur.reponse(code) }
        // Textes venus de l'extérieur : une ligne courte, sans lien ni balise.
        func propre(_ s: String, _ n: Int) -> String {
            String(s.replacingOccurrences(of: "://", with: " ").filter { $0.isLetter || $0.isNumber || " .,;:'()_-/+".contains($0) }.prefix(n))
        }
        var corrigee: [String] = []
        for a in v["affected"] as? [[String: Any]] ?? [] {
            for r in a["ranges"] as? [[String: Any]] ?? [] {
                for e in r["events"] as? [[String: Any]] ?? [] { if let f = e["fixed"] as? String, !corrigee.contains(f) { corrigee.append(propre(f, 40)) } }
            }
        }
        return Fiche(id: id, resume: propre((v["summary"] as? String) ?? (v["details"] as? String) ?? "", 160),
                     alias: ((v["aliases"] as? [String]) ?? []).filter(Self.identifiantValide).prefix(3).map { $0 },
                     gravite: propre(((v["database_specific"] as? [String: Any])?["severity"] as? String ?? "").uppercased(), 12),
                     corrigee: Array(corrigee.prefix(3)))
    }

    /// Ajoute au rapport un constat par dépendance touchée, puis recalcule le verdict.
    func completer(_ rapport: Rapport, dependances: [Dependance], annulation: Annulation? = nil) -> Rapport {
        var r = rapport
        guard !dependances.isEmpty else {
            r.couches.vulnerabilites = true
            r.resume += " Vulnérabilités connues : aucune dépendance à version exacte trouvée."
            return r
        }
        do {
            let ids = try chercher(dependances, annulation: annulation)
            var fiches: [String: Fiche] = [:]
            var aLire: [String] = []
            for liste in ids { for id in liste where !aLire.contains(id) { aLire.append(id) } }
            // Les paquets malveillants d'abord : ce sont les seuls qui changent le verdict.
            aLire.sort { ($0.hasPrefix("MAL-") ? 0 : 1, $0) < ($1.hasPrefix("MAL-") ? 0 : 1, $1) }
            let rangees = Rangement<Fiche>(min(aLire.count, Self.fichesMax))
            let ensemble = Array(aLire.prefix(Self.fichesMax))
            DispatchQueue.concurrentPerform(iterations: ensemble.count) { i in
                guard annulation?.demandee != true, let f = try? fiche(ensemble[i], annulation: annulation) else { return }
                rangees.ranger(i, f)
            }
            for f in rangees.tout { fiches[f.id] = f }
            try annulation?.verifier()
            var touchees = 0
            for (d, liste) in zip(dependances, ids) where !liste.isEmpty {
                touchees += 1
                let lignes = d.ligne > 0 ? [d.ligne, d.ligne] : []
                let qui = "\(d.ecosysteme) \(d.nom) \(d.version)"
                if let mal = liste.first(where: { $0.hasPrefix("MAL-") || fiches[$0]?.malveillant == true }) {
                    let f = fiches[mal]
                    r.constats.append(Constat(id: "", gravite: .critique, statut: .confirme, categorie: .dependances, titre: "Paquet malveillant connu : \(d.nom) \(d.version)",
                                              fichier: d.fichier, lignes: lignes, extrait: String("\(qui) — \(mal)\(f.map { " : \($0.resume)" } ?? "")".prefix(300)),
                                              explication: "La base OSV recense cette version comme malveillante : l'installer lancerait le code d'un attaquant.",
                                              origine: .regle, regle: "dep.malveillant"))
                    continue
                }
                let detail = liste.prefix(4).map { id -> String in
                    guard let f = fiches[id] else { return id }
                    let cve = f.alias.first { $0.hasPrefix("CVE-") }
                    return id + (cve.map { " (\($0))" } ?? "") + (f.gravite.isEmpty ? "" : " \(Self.gravite(f.gravite))")
                }.joined(separator: ", ")
                let corrige = liste.compactMap { fiches[$0]?.corrigee.last }.max { Self.avant($0, $1) }
                let grave = liste.contains { ["CRITICAL", "HIGH"].contains(fiches[$0]?.gravite ?? "") }
                r.constats.append(Constat(
                    id: "", gravite: grave ? .moyenne : .faible, statut: .confirme, categorie: .dependances,
                    titre: "Faille\(liste.count > 1 ? "s" : "") connue\(liste.count > 1 ? "s" : "") dans \(d.nom) \(d.version)",
                    fichier: d.fichier, lignes: lignes,
                    extrait: String("\(qui) — \(liste.count) faille\(liste.count > 1 ? "s" : "") : \(detail)\(liste.count > 4 ? "…" : "")\(corrige.map { " ; corrigé en \($0)" } ?? "")".prefix(300)),
                    explication: "Cette version a des failles publiées (base OSV). Ce n'est pas un signe de malveillance : mettre la dépendance à jour corrige le risque.",
                    origine: .regle, regle: "dep.faille"))
            }
            r.couches.vulnerabilites = true
            let ecos = Dictionary(grouping: dependances, by: \.ecosysteme).map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", ")
            r.resume += " Vulnérabilités connues : \(dependances.count) dépendance\(dependances.count > 1 ? "s" : "") comparée\(dependances.count > 1 ? "s" : "") à la base OSV (\(ecos)), \(touchees) touchée\(touchees > 1 ? "s" : "")."
        } catch {
            r.nonAnalyse.append(NonAnalyse(fichier: ".", raison: "vulnérabilités connues non vérifiées : \(error)"))
        }
        return Audit.reclasser(r)
    }

    static func gravite(_ s: String) -> String {
        ["CRITICAL": "critique", "HIGH": "élevée", "MODERATE": "moyenne", "MEDIUM": "moyenne", "LOW": "faible"][s] ?? s.lowercased()
    }

    /// Comparaison de versions morceau par morceau (« 4.17.9 » avant « 4.17.21 »).
    static func avant(_ a: String, _ b: String) -> Bool {
        let x = a.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }, y = b.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
        for (p, q) in zip(x, y) where p != q { return p < q }
        return x.count < y.count
    }

    /// Envoi réel : même garde que pour la réputation (un seul domaine, sans redirection ni cookie).
    static func envoyer(_ requete: URLRequest, annulation: Annulation?) throws -> (code: Int, donnees: Data) {
        guard requete.url?.scheme == "https", requete.url?.host() == domaine else { throw Erreur.reseau("domaine non prévu") }
        return try Reputation.envoyerVers(domaine, requete, annulation: annulation, erreur: Erreur.reseau)
    }
}

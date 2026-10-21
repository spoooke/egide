import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Vérifications qui sortent du Mac. Aucune n'est faite par défaut : chacune demande un accord donné pour l'audit en cours
/// (sauf la base OSV pour un dépôt public ou un paquet PyPI, voir `Vulnerabilites`).
public struct EnLigne: Sendable {
    /// Verdict de Gatekeeper (`spctl`) : pour le rendre, macOS peut interroger Apple.
    public var gatekeeper: Bool
    /// Base de réputation : seule l'empreinte SHA-256 est envoyée.
    public var reputation: Reputation?

    /// Base OSV : seuls l'écosystème, le nom et la version des dépendances sont envoyés.
    public var vulnerabilites: Vulnerabilites?

    public init(gatekeeper: Bool = false, reputation: Reputation? = nil, vulnerabilites: Vulnerabilites? = nil) {
        self.gatekeeper = gatekeeper
        self.reputation = reputation
        self.vulnerabilites = vulnerabilites
    }
}

/// Réputation d'un fichier d'après son empreinte, sur VirusTotal (domaine validé par l'utilisateur le 2026-10-13).
/// Seule l'empreinte SHA-256 part : ni le fichier, ni son nom, ni son chemin. Un seul domaine, sans redirection.
public struct Reputation: Sendable {
    public static let domaine = "www.virustotal.com"
    /// Empreintes envoyées au plus par audit (la clé gratuite permet quatre questions par minute).
    public static let empreintesMax = 4

    public enum Avis: Equatable, Sendable {
        case inconnu
        case connu(malveillant: Int, douteux: Int, moteurs: Int, etiquette: String)
    }

    public enum Erreur: Error, CustomStringConvertible, Equatable {
        case empreinte, cle, quota, reponse(Int), reseau(String)

        public var description: String {
            switch self {
            case .empreinte: "empreinte invalide"
            case .cle: "clé VirusTotal refusée"
            case .quota: "quota VirusTotal atteint (quatre questions par minute avec la clé gratuite)"
            case .reponse(let code): "réponse \(code) de \(Reputation.domaine)"
            case .reseau(let detail): "pas de réponse de \(Reputation.domaine) (\(detail))"
            }
        }
    }

    typealias Transport = @Sendable (URLRequest, Annulation?) throws -> (code: Int, donnees: Data)

    let cle: String
    let transport: Transport

    public init(cle: String) { self.init(cle: cle, transport: Reputation.envoyer) }

    init(cle: String, transport: @escaping Transport) {
        self.cle = cle
        self.transport = transport
    }

    /// La question posée : rien d'autre que l'empreinte dans l'adresse, et la clé dans un en-tête.
    static func requete(_ sha256: String, cle: String) throws -> URLRequest {
        let empreinte = sha256.lowercased()
        guard empreinte.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let url = URL(string: "https://\(domaine)/api/v3/files/\(empreinte)") else { throw Erreur.empreinte }
        var requete = URLRequest(url: url)
        requete.setValue(cle, forHTTPHeaderField: "x-apikey")
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        requete.setValue("cerbere-audit", forHTTPHeaderField: "User-Agent")
        return requete
    }

    public func chercher(_ sha256: String, annulation: Annulation? = nil) throws -> Avis {
        let (code, donnees) = try transport(Reputation.requete(sha256, cle: cle), annulation)
        switch code {
        case 200: break
        case 404: return .inconnu
        case 401, 403: throw Erreur.cle
        case 429: throw Erreur.quota
        default: throw Erreur.reponse(code)
        }
        guard let attributs = ((try? JSONSerialization.jsonObject(with: donnees)) as? [String: Any]).flatMap({ $0["data"] as? [String: Any] })?["attributes"] as? [String: Any],
              let bilan = attributs["last_analysis_stats"] as? [String: Any] else { throw Erreur.reponse(200) }
        func nombre(_ cle: String) -> Int { max(0, bilan[cle] as? Int ?? 0) }
        let etiquette = (attributs["popular_threat_classification"] as? [String: Any])?["suggested_threat_label"] as? String ?? ""
        return .connu(malveillant: nombre("malicious"), douteux: nombre("suspicious"),
                      moteurs: nombre("malicious") + nombre("suspicious") + nombre("undetected") + nombre("harmless"),
                      // Texte venu de l'extérieur : une ligne courte, lettres, chiffres et ponctuation simple.
                      etiquette: String(etiquette.filter { $0.isLetter || $0.isNumber || "._-/ :".contains($0) }.prefix(60)))
    }

    /// Ajoute au rapport l'avis de la base sur chaque empreinte (au plus `empreintesMax`), puis recalcule le verdict.
    func completer(_ rapport: Rapport, empreintes: [EmpreinteNommee], annulation: Annulation? = nil) -> Rapport {
        var r = rapport
        var vues = Set<String>()
        for e in empreintes.filter({ vues.insert($0.sha256).inserted }).prefix(Reputation.empreintesMax) {
            guard annulation?.demandee != true else { break }
            func constat(_ regle: String, _ gravite: Gravite, _ statut: Statut, _ titre: String, _ explication: String, _ detail: String) {
                r.constats.append(Constat(id: "", gravite: gravite, statut: statut, categorie: .autre, titre: titre, fichier: e.nom, lignes: [],
                                          extrait: "SHA-256 \(e.sha256) — \(detail)", explication: explication, origine: .regle, regle: regle))
            }
            do {
                let avis = try chercher(e.sha256, annulation: annulation)
                r.couches.reputation = true
                switch avis {
                case .inconnu:
                    constat("rep.inconnu", .info, .suspect, "Inconnu de VirusTotal",
                            "Personne n'a encore soumis ce fichier. Ce n'est ni bon ni mauvais signe : il peut être récent, rare, ou fabriqué pour toi.", "jamais vu")
                case .connu(let malveillant, let douteux, let moteurs, let etiquette):
                    let detail = "\(malveillant) antivirus sur \(moteurs) le disent malveillant" + (douteux > 0 ? ", \(douteux) douteux" : "") + (etiquette.isEmpty ? "" : " (\(etiquette))")
                    if malveillant >= 5 {
                        constat("rep.malveillant", .critique, .confirme, "Connu comme malveillant", "Plusieurs antivirus reconnaissent ce fichier précis comme un logiciel malveillant.", detail)
                    } else if malveillant + douteux > 0 {
                        constat("rep.douteux", .moyenne, .suspect, "Signalé par quelques antivirus", "Un petit nombre d'antivirus le signalent : souvent une fausse alerte, parfois un malware encore peu connu.", detail)
                    } else {
                        constat("rep.connu", .info, .confirme, "Connu de VirusTotal, sans alerte", "Ce fichier précis a déjà été analysé et aucun antivirus ne le signale.", detail)
                    }
                }
            } catch {
                r.nonAnalyse.append(NonAnalyse(fichier: e.nom, raison: "réputation non vérifiée : \(error)"))
                // Clé refusée ou quota atteint : inutile d'insister.
                if let erreur = error as? Erreur, erreur == .cle || erreur == .quota { break }
            }
        }
        return Audit.reclasser(r)
    }

    /// Envoi réel : session sans cookies ni cache, aucune redirection suivie, un seul domaine.
    static func envoyer(_ requete: URLRequest, annulation: Annulation?) throws -> (code: Int, donnees: Data) {
        guard requete.url?.scheme == "https", requete.url?.host() == domaine else { throw Erreur.reseau("domaine non prévu") }
        return try envoyerVers(domaine, requete, annulation: annulation, erreur: Erreur.reseau)
    }

    /// Envoi vers un seul domaine nommé (VirusTotal, OSV) : session sans cookies ni cache, aucune redirection suivie.
    static func envoyerVers(_ domaine: String, _ requete: URLRequest, annulation: Annulation?,
                            erreur: @escaping @Sendable (String) -> Error) throws -> (code: Int, donnees: Data) {
        final class Garde: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
            var resultat: Result<(code: Int, donnees: Data), Error>
            init(_ e: Error) { resultat = .failure(e) }
            func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
                completionHandler(nil)
            }
        }
        guard requete.url?.scheme == "https", requete.url?.host() == domaine else { throw erreur("domaine non prévu") }
        let reglages = URLSessionConfiguration.ephemeral
        reglages.httpCookieStorage = nil
        reglages.urlCache = nil
        reglages.timeoutIntervalForRequest = 30
        let garde = Garde(erreur("pas de réponse"))
        let session = URLSession(configuration: reglages, delegate: garde, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let fini = DispatchSemaphore(value: 0)
        let tache = session.dataTask(with: requete) { donnees, reponse, erreurReseau in
            if let e = erreurReseau { garde.resultat = .failure(erreur(e.localizedDescription)) }
            else if let http = reponse as? HTTPURLResponse { garde.resultat = .success((http.statusCode, (donnees ?? Data()).prefix(5_000_000))) }
            fini.signal()
        }
        tache.resume()
        while fini.wait(timeout: .now() + 0.2) == .timedOut {
            if annulation?.demandee == true { tache.cancel() }
        }
        try annulation?.verifier()
        return try garde.resultat.get()
    }
}

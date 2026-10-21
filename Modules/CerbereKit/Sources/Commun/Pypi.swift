import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Récupère ce que `pip install <paquet>` installerait, sans l'installer : l'archive « wheel » et l'archive
/// source de la dernière version, téléchargées telles quelles puis ouvertes en quarantaine.
/// Deux domaines seulement : pypi.org (fiche du paquet) et files.pythonhosted.org (archives).
public enum Pypi {
    public static let domaines: Set<String> = ["pypi.org", "files.pythonhosted.org"]

    public struct Archive: Equatable, Sendable {
        public let sorte: String      // « wheel » ou « sdist »
        public let nom: String
        public let url: URL
        public let sha256: String
        public let taille: Int
    }

    public struct Fiche: Equatable, Sendable {
        public let paquet: String
        public let version: String
        public let archives: [Archive]
    }

    /// Lit la fiche JSON de PyPI : dernière version, une wheel (de préférence universelle) et l'archive source.
    static func fiche(json: Data) throws -> Fiche {
        guard let racine = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let info = racine["info"] as? [String: Any], let paquet = info["name"] as? String, let version = info["version"] as? String,
              let urls = racine["urls"] as? [[String: Any]] else { throw ErreurCerbere.telechargementRefuse("fiche PyPI illisible") }
        func archive(_ entree: [String: Any], _ sorte: String) -> Archive? {
            guard let nom = entree["filename"] as? String, let adresse = entree["url"] as? String, let url = URL(string: adresse),
                  url.scheme == "https", let hote = url.host(), domaines.contains(hote),
                  let sha = (entree["digests"] as? [String: Any])?["sha256"] as? String, let taille = entree["size"] as? Int,
                  !nom.contains("/"), !nom.hasPrefix(".") else { return nil }
            return Archive(sorte: sorte, nom: nom, url: url, sha256: sha, taille: taille)
        }
        let wheels = urls.filter { $0["packagetype"] as? String == "bdist_wheel" }
        let wheel = (wheels.first { ($0["filename"] as? String)?.hasSuffix("-none-any.whl") == true }
            ?? wheels.first { ($0["filename"] as? String)?.contains("macosx") == true && ($0["filename"] as? String)?.contains("arm64") == true }
            ?? wheels.first).flatMap { archive($0, "wheel") }
        let source = urls.first { $0["packagetype"] as? String == "sdist" }.flatMap { archive($0, "sdist") }
        let archives = [wheel, source].compactMap { $0 }
        guard !archives.isEmpty else { throw ErreurCerbere.telechargementRefuse("aucune archive pour \(paquet) \(version)") }
        return Fiche(paquet: paquet, version: version, archives: archives)
    }

    public static func verifier(nom: String) throws -> String {
        guard nom.range(of: #"^[A-Za-z0-9]([A-Za-z0-9._-]{0,98}[A-Za-z0-9])?$"#, options: .regularExpression) != nil else {
            throw ErreurCerbere.telechargementRefuse("nom de paquet invalide")
        }
        return nom
    }

    /// Télécharge les archives (empreinte SHA-256 vérifiée contre la fiche) et les ouvre en quarantaine.
    public static func recuperer(paquet: String, racine: URL = Quarantaine.racine, annulation: Annulation? = nil) throws -> (Quarantaine, Fiche) {
        let nom = try verifier(nom: paquet)
        let fiche = try fiche(json: telecharger(URL(string: "https://pypi.org/pypi/\(nom)/json")!, max: 20_000_000, annulation: annulation))
        let fm = FileManager.default
        let depot = racine.appending(path: "telechargement-\(UUID().uuidString)")
        try fm.createDirectory(at: depot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { Plateforme.supprimer(depot) }
        var fichiers: [(nom: String, fichier: URL)] = []
        for archive in fiche.archives {
            guard archive.taille <= Quarantaine.archiveMax else { throw ErreurCerbere.archiveRefusee("\(archive.nom) fait plus de 300 Mo") }
            let fichier = depot.appending(path: archive.nom)
            try telecharger(archive.url, max: Quarantaine.archiveMax, annulation: annulation).write(to: fichier)
            try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: fichier.path)
            guard Quarantaine.empreinte(fichier) == archive.sha256.lowercased() else {
                throw ErreurCerbere.telechargementRefuse("empreinte de \(archive.nom) différente de celle annoncée par PyPI")
            }
            fichiers.append((archive.sorte, fichier))
        }
        let source = "pypi:\(fiche.paquet) \(fiche.version) (" + fiche.archives.map(\.nom).joined(separator: ", ") + ")"
        return (try Quarantaine.extraire(archives: fichiers, source: source, racine: racine, annulation: annulation), fiche)
    }

    /// Téléchargement simple, sans cookies ni cache, refusé si une redirection sort des deux domaines.
    static func telecharger(_ url: URL, max: Int, annulation: Annulation? = nil) throws -> Data {
        final class Garde: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
            var resultat: Result<Data, Error> = .failure(ErreurCerbere.telechargementRefuse("pas de réponse"))
            func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
                let permis = request.url?.scheme == "https" && Pypi.domaines.contains(request.url?.host() ?? "")
                completionHandler(permis ? request : nil)
            }
        }
        guard url.scheme == "https", let hote = url.host(), domaines.contains(hote) else {
            throw ErreurCerbere.telechargementRefuse("domaine non prévu : \(url.host() ?? "?")")
        }
        let reglages = URLSessionConfiguration.ephemeral
        reglages.httpCookieStorage = nil
        reglages.urlCache = nil
        reglages.timeoutIntervalForRequest = 60
        let garde = Garde()
        let session = URLSession(configuration: reglages, delegate: garde, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let fini = DispatchSemaphore(value: 0)
        var requete = URLRequest(url: url)
        requete.setValue("cerbere-audit", forHTTPHeaderField: "User-Agent")
        let tache = session.dataTask(with: requete) { donnees, reponse, erreur in
            if let erreur { garde.resultat = .failure(erreur) }
            else if let http = reponse as? HTTPURLResponse, http.statusCode == 200, let donnees, donnees.count <= max { garde.resultat = .success(donnees) }
            else { garde.resultat = .failure(ErreurCerbere.telechargementRefuse("réponse \((reponse as? HTTPURLResponse)?.statusCode ?? 0) pour \(url.lastPathComponent)")) }
            fini.signal()
        }
        tache.resume()
        // L'arrêt demandé par l'utilisateur coupe le téléchargement en cours.
        while fini.wait(timeout: .now() + 0.2) == .timedOut {
            if annulation?.demandee == true { tache.cancel() }
        }
        try annulation?.verifier()
        return try garde.resultat.get()
    }
}

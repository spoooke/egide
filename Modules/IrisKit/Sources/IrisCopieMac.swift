import Foundation

/// Copie des scans dans un dossier choisi (iCloud Drive › Iris, par exemple), pour les retrouver sur le Mac :
/// Finder, Coup d'œil, et Spotlight qui cherche dans le texte des PDF. Un sous-dossier par genre (Tickets,
/// Factures, Documents). Rien n'est copié tant qu'aucun dossier
/// n'est choisi. Le signet du dossier reste sur cet iPhone (UserDefaults), hors de la sauvegarde globale :
/// il ne vaut que pour cet appareil. Un scan supprimé dans Iris reste dans le dossier.
@MainActor
public struct IrisCopieMac {
    let stockage: UserDefaults

    enum Cle {
        static let signet = "iris.mac.signet"
        static let nom = "iris.mac.dossier"
        static let erreur = "iris.mac.erreur"
        static let date = "iris.mac.date"
    }

    public init(_ stockage: UserDefaults = .standard) {
        self.stockage = stockage
    }

    /// Nom du dossier choisi ; nil : pas de copie.
    public var nomDossier: String? { signet == nil ? nil : stockage.string(forKey: Cle.nom) }
    /// Dernier échec de copie, effacé à la copie suivante réussie.
    public var erreur: String? { stockage.string(forKey: Cle.erreur) }
    public var derniereCopie: Date? { stockage.object(forKey: Cle.date) as? Date }

    private var signet: Data? { stockage.data(forKey: Cle.signet) }

    /// Dossier choisi dans Fichiers : son signet est gardé pour y écrire plus tard.
    public func choisir(_ url: URL) throws {
        let acces = url.startAccessingSecurityScopedResource()
        defer { if acces { url.stopAccessingSecurityScopedResource() } }
        stockage.set(try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil), forKey: Cle.signet)
        stockage.set(url.lastPathComponent, forKey: Cle.nom)
        stockage.removeObject(forKey: Cle.erreur)
    }

    public func arreter() {
        for cle in [Cle.signet, Cle.nom, Cle.erreur, Cle.date] { stockage.removeObject(forKey: cle) }
    }

    /// Copie les scans dans le dossier choisi ; rien si aucun. `saufDejaLa` : un nom déjà présent n'est pas
    /// recopié (« Copier les scans déjà faits ») ; sinon un nom pris reçoit « (2) ». L'échec est noté pour
    /// les réglages, jamais levé : le mail part quand même. Renvoie le nombre de PDF copiés.
    @discardableResult
    public func copier(_ scans: [IrisScan], saufDejaLa: Bool = false) async -> Int {
        guard let signet, !scans.isEmpty else { return 0 }
        let fichiers = scans.map(\.url)
        do {
            let (copies, neuf) = try await Task.detached {
                try Self.copier(fichiers, signet: signet, saufDejaLa: saufDejaLa)
            }.value
            if let neuf { stockage.set(neuf, forKey: Cle.signet) }
            stockage.removeObject(forKey: Cle.erreur)
            if copies > 0 { stockage.set(Date.now, forKey: Cle.date) }
            return copies
        } catch {
            stockage.set("Copie impossible : \(error.localizedDescription)", forKey: Cle.erreur)
            return 0
        }
    }

    /// Range la copie d'un scan dont le genre a changé (voir `deplacer(_:vers:dans:)`) ; rien si aucun dossier.
    public func deplacer(_ ancien: IrisScan, vers scan: IrisScan) async {
        guard let signet, ancien.nom != scan.nom else { return }
        let (nom, fichier) = (ancien.nom, scan.url)
        do {
            let neuf = try await Task.detached {
                try Self.ouvrir(signet) { try Self.deplacer(nom, vers: fichier, dans: $0) }
            }.value
            if let neuf { stockage.set(neuf, forKey: Cle.signet) }
            stockage.removeObject(forKey: Cle.erreur)
            stockage.set(Date.now, forKey: Cle.date)
        } catch {
            stockage.set("Copie impossible : \(error.localizedDescription)", forKey: Cle.erreur)
        }
    }

    // MARK: - Fichiers (hors thread principal)

    /// Ouvre le dossier du signet le temps de la copie ; renvoie aussi un signet refait s'il était périmé.
    private nonisolated static func copier(_ fichiers: [URL], signet: Data, saufDejaLa: Bool) throws -> (Int, Data?) {
        var copies = 0
        let neuf = try ouvrir(signet) { copies = try copier(fichiers, dans: $0, saufDejaLa: saufDejaLa) }
        return (copies, neuf)
    }

    /// Dossier du signet ouvert le temps de `action` ; renvoie un signet refait s'il était périmé.
    private nonisolated static func ouvrir(_ signet: Data, _ action: (URL) throws -> Void) throws -> Data? {
        var perime = false
        let dossier = try URL(resolvingBookmarkData: signet, options: [], relativeTo: nil, bookmarkDataIsStale: &perime)
        let acces = dossier.startAccessingSecurityScopedResource()
        defer { if acces { dossier.stopAccessingSecurityScopedResource() } }
        try action(dossier)
        return perime ? try? dossier.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) : nil
    }

    /// Chaque scan va dans le sous-dossier de son genre (Tickets, Factures, Documents), créé au besoin ;
    /// un PDF partagé, sans genre dans son nom, reste à la racine du dossier.
    nonisolated static func copier(_ fichiers: [URL], dans dossier: URL, saufDejaLa: Bool) throws -> Int {
        var pris: [URL: Set<String>] = [:]
        let racine = presents(dans: dossier)
        var copies = 0
        for fichier in fichiers {
            let base = fichier.deletingPathExtension().lastPathComponent
            let cible = try sousDossier(de: base, dans: dossier)
            var noms = pris[cible] ?? presents(dans: cible)
            // Les copies d'avant les sous-dossiers, à la racine, comptent comme déjà là.
            if saufDejaLa && (noms.contains(base.lowercased()) || racine.contains(base.lowercased())) { continue }
            let nom = IrisNom.libre(base, pris: noms)
            try ecrire(try Data(contentsOf: fichier), vers: cible.appending(path: nom + ".pdf"))
            noms.insert(nom.lowercased())
            pris[cible] = noms
            copies += 1
        }
        return copies
    }

    /// Sous-dossier du genre lu dans le nom, créé au besoin ; le dossier lui-même pour un nom sans genre.
    nonisolated static func sousDossier(de nom: String, dans dossier: URL) throws -> URL {
        guard let genre = IrisGenre(nom: nom) else { return dossier }
        let url = dossier.appending(path: genre.dossier, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Après un changement de genre : la copie sous l'ancien nom (dans son sous-dossier, ou à la racine)
    /// est retirée, puis le scan renommé est copié dans le sous-dossier de son nouveau genre.
    nonisolated static func deplacer(_ ancien: String, vers fichier: URL, dans dossier: URL) throws {
        for lieu in [try sousDossier(de: ancien, dans: dossier), dossier] {
            let url = lieu.appending(path: ancien + ".pdf")
            if FileManager.default.fileExists(atPath: url.path) {
                try retirer(url)
                break
            }
        }
        _ = try copier([fichier], dans: dossier, saufDejaLa: false)
    }

    /// Noms des PDF du dossier (en minuscules, sans extension), y compris ceux pas encore téléchargés
    /// depuis iCloud (« .Ticket 2026-10-16.pdf.icloud »).
    nonisolated static func presents(dans dossier: URL) -> Set<String> {
        let noms = (try? FileManager.default.contentsOfDirectory(atPath: dossier.path)) ?? []
        return Set(noms.compactMap { nom in
            var fichier = nom
            if nom.hasPrefix("."), nom.hasSuffix(".icloud") { fichier = String(nom.dropFirst().dropLast(".icloud".count)) }
            guard fichier.lowercased().hasSuffix(".pdf") else { return nil }
            return String(fichier.dropLast(4)).lowercased()
        })
    }

    /// Écriture coordonnée : iCloud Drive envoie le fichier une fois complet.
    private nonisolated static func ecrire(_ data: Data, vers url: URL) throws {
        var erreurCoordination: NSError?
        var erreurEcriture: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &erreurCoordination) { cible in
            do { try data.write(to: cible, options: .atomic) } catch { erreurEcriture = error }
        }
        if let erreur = erreurCoordination ?? erreurEcriture { throw erreur }
    }

    /// Suppression coordonnée, pour qu'iCloud Drive la suive.
    private nonisolated static func retirer(_ url: URL) throws {
        var erreurCoordination: NSError?
        var erreurSuppression: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &erreurCoordination) { cible in
            do { try FileManager.default.removeItem(at: cible) } catch { erreurSuppression = error }
        }
        if let erreur = erreurCoordination ?? erreurSuppression { throw erreur }
    }
}

import Foundation

/// Arrêt demandé par l'utilisateur pendant un audit : les outils en cours (git, bsdtar, claude) sont interrompus,
/// et chaque étape s'arrête dès qu'elle le voit. L'audit se termine alors par `ErreurCerbere.annule`.
public final class Annulation: @unchecked Sendable {
    private let verrou = NSLock()
    private var etat = false
    private var processus: [Process] = []

    public init() {}

    public var demandee: Bool {
        verrou.lock()
        defer { verrou.unlock() }
        return etat
    }

    public func annuler() {
        verrou.lock()
        etat = true
        let enCours = processus
        verrou.unlock()
        for p in enCours where p.isRunning { p.terminate() }
    }

    func verifier() throws {
        if demandee { throw ErreurCerbere.annule }
    }

    /// À appeler juste après le lancement d'un outil : il sera interrompu si l'arrêt est demandé (ou l'a déjà été).
    func suivre(_ p: Process) {
        verrou.lock()
        processus.append(p)
        let deja = etat
        verrou.unlock()
        if deja, p.isRunning { p.terminate() }
    }

    func oublier(_ p: Process) {
        verrou.lock()
        processus.removeAll { $0 === p }
        verrou.unlock()
    }
}

/// Où en est l'audit, pour l'affichage (outil en ligne de commande : `message` ; app : étape et compteur).
public struct Avancement: Sendable, Equatable {
    public enum Etape: Int, Sendable, CaseIterable, Comparable {
        case recuperation, regles, lecture, relecture, resume

        public static func < (a: Etape, b: Etape) -> Bool { a.rawValue < b.rawValue }
    }

    public var etape: Etape
    /// Phrase à afficher ; vide quand seul le compteur a bougé.
    public var message: String
    /// Lots de lecture terminés et prévus (étape `lecture`).
    public var fait = 0
    public var total = 0
    /// Détail pour le journal du travail en cours (fichiers envoyés, constats trouvés…), pas pour la ligne d'état.
    public var lignes: [String] = []

    public init(_ etape: Etape, _ message: String = "", fait: Int = 0, total: Int = 0, lignes: [String] = []) {
        self.etape = etape
        self.message = message
        self.fait = fait
        self.total = total
        self.lignes = lignes
    }

    /// « [Élevée · suspect] titre — fichier:12 », pour le journal.
    static func ligne(_ c: Constat) -> String {
        let lieu = c.lignes.isEmpty ? c.fichier : c.lignes.first == c.lignes.last ? "\(c.fichier):\(c.lignes[0])" : "\(c.fichier):\(c.lignes[0])-\(c.lignes.last!)"
        return "[\(c.gravite.titre) · \(c.statut == .confirme ? "confirmé" : "suspect")] \(c.titre) — \(lieu)"
    }
}

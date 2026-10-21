import Foundation

/// Journal du travail en cours : chaque audit (app Mac, outil, relais de l'iPhone) écrit ce qu'il fait dans un fichier
/// `<identifiant>.jsonl` (une ligne JSON par événement), que la fenêtre « Travail en cours » de l'app relit en direct.
/// Rien n'en sort de la machine. Les textes venus du code audité (titres, chemins) y sont des données, affichées en texte brut.
public final class JournalAudit: @unchecked Sendable {
    public enum Origine: String, Codable, Sendable { case app, outil, iphone }

    public static var dossier: URL {
        Plateforme.caches.appending(path: "journal")
    }
    /// Lignes écrites au plus par audit : un dépôt énorme ne remplit pas le disque.
    static let lignesMax = 5000
    /// Journaux plus vieux effacés à l'ouverture d'un nouveau.
    static let garde: TimeInterval = 24 * 3600

    public let fichier: URL
    private let poignee: FileHandle?
    private let verrou = NSLock()
    private var ecrites = 0
    private var finie = false

    /// Événement : en-tête (`cible`…), avancement (`etape`, `message`, `lignes`), ou fin (`verdict` ou `erreur`).
    struct Evenement: Codable {
        var t: Date
        var origine: Origine?
        var cible: String?
        var pid: Int32?
        var etape: Int?
        var message: String?
        var fait: Int?
        var total: Int?
        var lignes: [String]?
        var fin: Bool?
        var verdict: Verdict?
        var erreur: String?
    }

    public init(origine: Origine, cible: String, dossier: URL = JournalAudit.dossier, date: Date = .now) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dossier, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        Self.nettoyer(dossier, avant: date.addingTimeInterval(-Self.garde))
        fichier = dossier.appending(path: "\(Int(date.timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).jsonl")
        fm.createFile(atPath: fichier.path, contents: nil, attributes: [.posixPermissions: 0o600])
        poignee = try? FileHandle(forWritingTo: fichier)
        ecrire(Evenement(t: date, origine: origine, cible: cible, pid: ProcessInfo.processInfo.processIdentifier))
    }

    deinit { try? poignee?.close() }

    /// Note un avancement, puis le passe à `suivant`.
    public func suivi(_ suivant: @escaping @Sendable (Avancement) -> Void = { _ in }) -> @Sendable (Avancement) -> Void {
        { [self] a in
            noter(a)
            suivant(a)
        }
    }

    public func noter(_ a: Avancement) {
        ecrire(Evenement(t: .now, etape: a.etape.rawValue, message: a.message.isEmpty ? nil : a.message,
                         fait: a.total > 0 ? a.fait : nil, total: a.total > 0 ? a.total : nil, lignes: a.lignes.isEmpty ? nil : a.lignes))
    }

    public func terminer(verdict: Verdict) { ecrire(Evenement(t: .now, fin: true, verdict: verdict)) }

    public func terminer(erreur: Error) {
        let texte = (erreur as? ErreurCerbere) == .annule ? "Audit annulé." : "\(erreur)"
        ecrire(Evenement(t: .now, fin: true, erreur: String(texte.prefix(300))))
    }

    private func ecrire(_ e: Evenement) {
        verrou.lock()
        defer { verrou.unlock() }
        guard !finie, let poignee else { return }
        var e = e
        if e.cible != nil {
            // En-tête : ne compte pas.
        } else if e.fin != true {
            guard ecrites < Self.lignesMax else { return }
            if let lignes = e.lignes { e.lignes = Array(lignes.prefix(Self.lignesMax - ecrites)) }
            ecrites += max(1, e.lignes?.count ?? 0)
        } else {
            finie = true
        }
        let encodeur = JSONEncoder()
        encodeur.dateEncodingStrategy = .iso8601
        guard let donnees = try? encodeur.encode(e) else { return }
        try? poignee.write(contentsOf: donnees + Data("\n".utf8))
    }

    static func nettoyer(_ dossier: URL, avant limite: Date) {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: dossier, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where f.pathExtension == "jsonl" {
            if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < limite { try? fm.removeItem(at: f) }
        }
    }
}

/// Un journal relu par la fenêtre « Travail en cours ».
public struct JournalLu: Identifiable, Equatable, Sendable {
    public struct Ligne: Equatable, Sendable {
        public var date: Date
        public var texte: String
        /// Phrase d'étape (en gras) plutôt que détail.
        public var etape: Bool
    }

    public var id: String
    public var origine: JournalAudit.Origine
    public var cible: String
    public var debut: Date
    public var etape: Avancement.Etape = .recuperation
    public var message = ""
    public var fait = 0
    public var total = 0
    public var lignes: [Ligne] = []
    public var fin: Date?
    public var verdict: Verdict?
    public var erreur: String?
    /// Le programme qui l'écrivait s'est arrêté sans finir (app quittée, relais relancé).
    public var interrompu = false

    public var enCours: Bool { fin == nil && !interrompu }

    /// Relit un journal ; `nil` s'il est illisible.
    public init?(fichier: URL) {
        guard let donnees = try? Data(contentsOf: fichier) else { return nil }
        let decodeur = JSONDecoder()
        decodeur.dateDecodingStrategy = .iso8601
        var entete: JournalAudit.Evenement?
        var lu = JournalLu(id: fichier.lastPathComponent, origine: .app, cible: "", debut: .distantPast)
        for brut in donnees.split(separator: UInt8(ascii: "\n")) {
            guard let e = try? decodeur.decode(JournalAudit.Evenement.self, from: Data(brut)) else { continue }
            if entete == nil, let cible = e.cible {
                entete = e
                lu.cible = cible
                lu.origine = e.origine ?? .app
                lu.debut = e.t
                continue
            }
            if let n = e.etape, let etape = Avancement.Etape(rawValue: n) { lu.etape = max(lu.etape, etape) }
            if let total = e.total {
                lu.total = total
                lu.fait = max(lu.fait, e.fait ?? 0)
            }
            if let m = e.message {
                lu.message = m
                lu.lignes.append(Ligne(date: e.t, texte: m, etape: true))
            }
            for l in e.lignes ?? [] { lu.lignes.append(Ligne(date: e.t, texte: l, etape: false)) }
            if e.fin == true {
                lu.fin = e.t
                lu.verdict = e.verdict
                lu.erreur = e.erreur
            }
        }
        guard let entete else { return nil }
        if lu.fin == nil, let pid = entete.pid, Plateforme.processusDisparu(pid) { lu.interrompu = true }
        self = lu
    }

    private init(id: String, origine: JournalAudit.Origine, cible: String, debut: Date) {
        self.id = id
        self.origine = origine
        self.cible = cible
        self.debut = debut
    }

    /// Tous les journaux du dossier, les audits en cours d'abord, puis du plus récent au plus ancien.
    public static func lire(dans dossier: URL = JournalAudit.dossier) -> [JournalLu] {
        let fichiers = (try? FileManager.default.contentsOfDirectory(at: dossier, includingPropertiesForKeys: nil)) ?? []
        return fichiers.filter { $0.pathExtension == "jsonl" }.compactMap(JournalLu.init(fichier:))
            .sorted { ($0.enCours ? 1 : 0, $0.debut) > ($1.enCours ? 1 : 0, $1.debut) }
    }
}

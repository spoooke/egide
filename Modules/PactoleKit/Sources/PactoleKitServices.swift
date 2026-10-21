import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// Services de Money pour l'app : résumé de l'Accueil, sauvegarde globale.
extension PactoleKit {
    /// « 92 € à dépenser cette semaine » (ou le dépassement).
    @MainActor
    public static func summary() async -> String? {
        let context = PactoleDatabase.container.mainContext
        guard let depenses = try? context.fetch(FetchDescriptor<Depense>()),
              let postes = try? context.fetch(FetchDescriptor<Poste>()) else { return nil }
        let horsPlafond = Set(postes.filter(\.horsPlafondHebdo).map(\.syncID))
        let total = Cumuls.totalSemaine(depenses, postesHorsPlafond: horsPlafond, semaine: Periodes.semaine(contenant: .now))
        let reste = PactoleReglages.plafondHebdoCentimes - total
        var texte = reste >= 0 ? "\(Montant.texte(reste)) à dépenser cette semaine" : "\(Montant.texte(-reste)) de dépassement"
        let aVerifier = depenses.filter(\.aVerifier).count
        if aVerifier > 0 { texte += " · \(aVerifier) à vérifier" }
        return texte
    }

    /// Paiement transmis par l'action Raccourcis « Ajouter une dépense » (automatisation « Transaction » de Wallet),
    /// sans ouvrir l'app. Renvoie une phrase courte pour la notification de Raccourcis.
    @MainActor
    public static func ajouterPaiement(commercant: String, montant: String, carte: String?, date: Date?) throws -> String {
        // Un « ; » copié avec la variable depuis la ligne du CSV ne doit pas faire échouer l'enregistrement.
        let separateurs = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ";"))
        let commercant = commercant.trimmingCharacters(in: separateurs)
        let montant = montant.trimmingCharacters(in: separateurs)
        let carte = carte?.trimmingCharacters(in: separateurs)
        guard let centimes = Montant.centimes(depuis: montant) else { throw Paiements.Erreur.montantInvalide(montant) }
        let context = PactoleDatabase.container.mainContext
        switch try Paiements.ajouter(commercant: commercant, centimes: centimes, carte: carte ?? "", date: date ?? .now,
                                     dans: context) {
        case .doublon:
            return "Déjà enregistré : \(Montant.texte(centimes)) chez \(commercant)."
        case .ajoutee(let posteID, let aVerifier), .rapprochee(let posteID, let aVerifier):
            let poste = (try? context.fetch(FetchDescriptor<Poste>()))?.first { $0.syncID == posteID }?.nom ?? posteID
            return "\(Montant.texte(centimes)) en \(poste)" + (aVerifier ? " (à vérifier dans Pactole)." : ".")
        }
    }

    /// Types de reçus acceptés : PDF, images et captures, texte, HTML, mails.
    public static let typesRecu: [UTType] = [.pdf, .image, .plainText, .html, .emailMessage, .text]

    /// Reçu partagé vers l'app (« Ouvrir dans Égide », glisser sur la fenêtre du Mac) : l'onglet Money le lit
    /// et ouvre la saisie pré-remplie. Faux si le fichier n'est pas un reçu lisible.
    @MainActor @discardableResult
    public static func recevoirRecu(_ url: URL) -> Bool {
        let acces = url.startAccessingSecurityScopedResource()
        defer { if acces { url.stopAccessingSecurityScopedResource() } }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()),
              typesRecu.contains(where: type.conforms(to:)),
              let data = try? Data(contentsOf: url) else { return false }
        // Copie déposée par « Ouvrir dans » dans Documents/Inbox : plus utile une fois lue.
        if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
        RecuEnAttente.shared.deposer(data, type: type)
        return true
    }

    /// Reçu transmis par l'action Raccourcis « Lire un reçu » (feuille de partage : capture, PDF, texte).
    @MainActor
    public static func recevoirRecu(data: Data, nomFichier: String?, typeIdentifier: String?) {
        let type = typeIdentifier.flatMap(UTType.init)
            ?? nomFichier.flatMap { UTType(filenameExtension: ($0 as NSString).pathExtension.lowercased()) }
            ?? .plainText
        RecuEnAttente.shared.deposer(data, type: type)
    }

    /// Dépenses, postes et plafond de la semaine.
    @MainActor
    public static func backup() throws -> Data? {
        try PactoleBackup.make(from: PactoleDatabase.container.mainContext).encoded()
    }

    /// Ajoute ce qui manque, ne remplace que par plus récent.
    @MainActor
    public static func restore(_ data: Data) throws -> String {
        try PactoleBackup.decode(data).restaurer(dans: PactoleDatabase.container.mainContext)
    }
}

/// Fichier JSON de la sauvegarde de Money, pour la fenêtre d'export (Réglages › Sauvegarde).
struct PactoleBackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Contenu de la sauvegarde de Money (même format que les futurs fichiers de synchro, phase 4).
struct PactoleBackup: Codable, Equatable {
    struct DepenseRecord: Codable, Equatable {
        var syncID: String, date: Date, montantCentimes: Int, posteID: String, note: String, source: String
        var createdAt: Date, modifiedAt: Date
        var commercant: String? = nil, carte: String? = nil, aVerifier: Bool? = nil
        /// Absent des fichiers d'avant le relevé bancaire (phase 7).
        var banqueID: String? = nil
        /// Frais pro remboursé (absent : pas remboursé).
        var rembourseLe: Date? = nil
    }
    struct RegleRecord: Codable, Equatable {
        var syncID: String, motif: String, posteID: String, modifiedAt: Date
    }
    struct PosteRecord: Codable, Equatable {
        var syncID: String, nom: String, symbole: String, plafondMensuelCentimes: Int?, horsPlafondHebdo: Bool, ordre: Int
        var modifiedAt: Date
    }

    struct FraisRecord: Codable, Equatable {
        var syncID: String, nom: String, montantCentimes: Int, jour: Int, categorie: String, actif: Bool, modifiedAt: Date
        /// Absent des fichiers d'avant les frais annuels (nil : mensuel).
        var moisAnnuel: Int? = nil
        /// Absent des fichiers d'avant le relevé bancaire.
        var motifBanque: String? = nil
    }
    struct RevenuRecord: Codable, Equatable {
        var syncID: String, mois: String, libelle: String, montantCentimes: Int, modifiedAt: Date
    }
    struct VirementRecord: Codable, Equatable {
        var syncID: String, date: Date, montantCentimes: Int, note: String, modifiedAt: Date
    }
    struct TombstoneRecord: Codable, Equatable {
        var syncID: String, deletedAt: Date
    }

    var version = 1
    var plafondHebdoCentimes: Int
    var postes: [PosteRecord]
    var depenses: [DepenseRecord]
    var regles: [RegleRecord]? = nil
    var fraisFixes: [FraisRecord]? = nil
    var revenus: [RevenuRecord]? = nil
    /// Absent des fichiers d'avant les virements (phase 9).
    var virements: [VirementRecord]? = nil
    // Fichier de synchro (absents d'une sauvegarde) :
    var deviceID: String? = nil
    var deviceName: String? = nil
    var plafondHebdoModifie: Date? = nil
    var tresorerie: ReglagesTresorerie? = nil
    var tresorerieModifie: Date? = nil
    var tombstones: [TombstoneRecord]? = nil

    @MainActor
    static func make(from context: ModelContext) throws -> PactoleBackup {
        PactoleBackup(
            plafondHebdoCentimes: PactoleReglages.plafondHebdoCentimes,
            // Un plafond changé après la sauvegarde n'est pas écrasé à la restauration.
            postes: try context.fetch(FetchDescriptor<Poste>()).map {
                PosteRecord(syncID: $0.syncID, nom: $0.nom, symbole: $0.symbole, plafondMensuelCentimes: $0.plafondMensuelCentimes,
                            horsPlafondHebdo: $0.horsPlafondHebdo, ordre: $0.ordre, modifiedAt: $0.modifiedAt)
            },
            depenses: try context.fetch(FetchDescriptor<Depense>()).map {
                DepenseRecord(syncID: $0.syncID, date: $0.date, montantCentimes: $0.montantCentimes, posteID: $0.posteID,
                              note: $0.note, source: $0.sourceRaw, createdAt: $0.createdAt, modifiedAt: $0.modifiedAt,
                              commercant: $0.commercant, carte: $0.carte, aVerifier: $0.aVerifier,
                              banqueID: $0.banqueID.isEmpty ? nil : $0.banqueID, rembourseLe: $0.rembourseLe)
            },
            regles: try context.fetch(FetchDescriptor<Regle>()).map {
                RegleRecord(syncID: $0.syncID, motif: $0.motif, posteID: $0.posteID, modifiedAt: $0.modifiedAt)
            },
            fraisFixes: try context.fetch(FetchDescriptor<FraisFixe>()).map {
                FraisRecord(syncID: $0.syncID, nom: $0.nom, montantCentimes: $0.montantCentimes, jour: $0.jour,
                            categorie: $0.categorieRaw, actif: $0.actif, modifiedAt: $0.modifiedAt,
                            moisAnnuel: $0.moisAnnuel, motifBanque: $0.motifBanque.isEmpty ? nil : $0.motifBanque)
            },
            revenus: try context.fetch(FetchDescriptor<Revenu>()).map {
                RevenuRecord(syncID: $0.syncID, mois: $0.mois, libelle: $0.libelle, montantCentimes: $0.montantCentimes,
                             modifiedAt: $0.modifiedAt)
            },
            virements: try context.fetch(FetchDescriptor<Virement>()).map {
                VirementRecord(syncID: $0.syncID, date: $0.date, montantCentimes: $0.montantCentimes, note: $0.note,
                               modifiedAt: $0.modifiedAt)
            },
            plafondHebdoModifie: PactoleReglages.plafondHebdoModifie,
            tresorerie: PactoleReglages.tresorerie,
            tresorerieModifie: PactoleReglages.tresorerieModifie)
    }

    /// Ajoute les éléments absents, remplace les présents seulement par une version plus récente.
    /// Renvoie le nombre d'éléments ajoutés ou mis à jour. Le plafond de la semaine est repris s'il est plus récent
    /// (ou toujours, pour une sauvegarde qui n'a pas sa date).
    @MainActor
    func restore(into context: ModelContext) throws -> Int {
        try PactoleSync.merge([self], into: context)
    }

    /// Restauration depuis Réglages (Money ou Égide) : fusion, puis synchro vers l'autre appareil. Compte rendu court.
    @MainActor
    func restaurer(dans context: ModelContext) throws -> String {
        let count = try restore(into: context)
        if count > 0 { PactoleSync.shared.scheduleSync() }
        return count == 0 ? "déjà à jour" : "\(count) élément(s) restauré(s)"
    }

    /// « Pactole-sauvegarde-2026-10-08 » (l'extension .json est ajoutée par la fenêtre d'export).
    static func nomFichier(now: Date = .now) -> String {
        "Pactole-sauvegarde-\(now.formatted(.iso8601.year().month().day()))"
    }

    /// Fusion d'un fichier, sans enregistrer. `supprimes` : traces de suppression connues (syncID → date).
    @MainActor
    func appliquer(dans context: ModelContext, supprimes: [String: Date]) throws -> Int {
        func supprime(_ id: String, _ modifie: Date) -> Bool { (supprimes[id] ?? .distantPast) >= modifie }
        var changes = 0
        let postesLocaux = Dictionary(try context.fetch(FetchDescriptor<Poste>()).map { ($0.syncID, $0) }) { a, _ in a }
        for r in postes {
            if let p = postesLocaux[r.syncID] {
                guard r.modifiedAt > p.modifiedAt else { continue }
                p.nom = r.nom; p.symbole = r.symbole; p.plafondMensuelCentimes = r.plafondMensuelCentimes
                p.horsPlafondHebdo = r.horsPlafondHebdo; p.ordre = r.ordre; p.modifiedAt = r.modifiedAt
            } else {
                let p = Poste(syncID: r.syncID, nom: r.nom, symbole: r.symbole, plafondMensuelCentimes: r.plafondMensuelCentimes,
                              horsPlafondHebdo: r.horsPlafondHebdo, ordre: r.ordre)
                p.modifiedAt = r.modifiedAt
                context.insert(p)
            }
            changes += 1
        }
        let depensesLocales = Dictionary(try context.fetch(FetchDescriptor<Depense>()).map { ($0.syncID, $0) }) { a, _ in a }
        for r in depenses where !supprime(r.syncID, r.modifiedAt) {
            let d: Depense
            if let existante = depensesLocales[r.syncID] {
                guard r.modifiedAt > existante.modifiedAt else { continue }
                d = existante
            } else {
                d = Depense(montantCentimes: r.montantCentimes, posteID: r.posteID)
                d.syncID = r.syncID
                context.insert(d)
            }
            d.date = r.date; d.montantCentimes = r.montantCentimes; d.posteID = r.posteID; d.note = r.note
            d.sourceRaw = r.source; d.createdAt = r.createdAt; d.modifiedAt = r.modifiedAt
            d.commercant = r.commercant ?? ""; d.carte = r.carte ?? ""; d.aVerifier = r.aVerifier ?? false
            // Un appareil d'avant le relevé bancaire n'efface pas le rapprochement fait sur le Mac.
            if let banqueID = r.banqueID { d.banqueID = banqueID }
            d.rembourseLe = r.rembourseLe
            changes += 1
        }
        let reglesLocales = Dictionary(try context.fetch(FetchDescriptor<Regle>()).map { ($0.syncID, $0) }) { a, _ in a }
        for r in (regles ?? []) where !supprime(r.syncID, r.modifiedAt) {
            if let regle = reglesLocales[r.syncID] {
                guard r.modifiedAt > regle.modifiedAt else { continue }
                regle.motif = r.motif; regle.posteID = r.posteID; regle.modifiedAt = r.modifiedAt
            } else {
                let regle = Regle(syncID: r.syncID, motif: r.motif, posteID: r.posteID)
                regle.modifiedAt = r.modifiedAt
                context.insert(regle)
            }
            changes += 1
        }
        let fraisLocaux = Dictionary(try context.fetch(FetchDescriptor<FraisFixe>()).map { ($0.syncID, $0) }) { a, _ in a }
        for r in (fraisFixes ?? []) where !supprime(r.syncID, r.modifiedAt) {
            let f: FraisFixe
            if let existant = fraisLocaux[r.syncID] {
                guard r.modifiedAt > existant.modifiedAt else { continue }
                f = existant
            } else {
                f = FraisFixe(nom: r.nom, montantCentimes: r.montantCentimes, jour: r.jour, categorie: .autre)
                f.syncID = r.syncID
                context.insert(f)
            }
            f.nom = r.nom; f.montantCentimes = r.montantCentimes; f.jour = r.jour; f.categorieRaw = r.categorie
            f.actif = r.actif; f.moisAnnuel = r.moisAnnuel; f.modifiedAt = r.modifiedAt
            if let motif = r.motifBanque { f.motifBanque = motif }
            changes += 1
        }
        let revenusLocaux = Dictionary(try context.fetch(FetchDescriptor<Revenu>()).map { ($0.syncID, $0) }) { a, _ in a }
        for r in (revenus ?? []) where !supprime(r.syncID, r.modifiedAt) {
            let v: Revenu
            if let existant = revenusLocaux[r.syncID] {
                guard r.modifiedAt > existant.modifiedAt else { continue }
                v = existant
            } else {
                v = Revenu(mois: r.mois, libelle: r.libelle, montantCentimes: r.montantCentimes)
                v.syncID = r.syncID
                context.insert(v)
            }
            v.mois = r.mois; v.libelle = r.libelle; v.montantCentimes = r.montantCentimes; v.modifiedAt = r.modifiedAt
            changes += 1
        }
        let virementsLocaux = Dictionary(try context.fetch(FetchDescriptor<Virement>()).map { ($0.syncID, $0) }) { a, _ in a }
        for r in (virements ?? []) where !supprime(r.syncID, r.modifiedAt) {
            let v: Virement
            if let existant = virementsLocaux[r.syncID] {
                guard r.modifiedAt > existant.modifiedAt else { continue }
                v = existant
            } else {
                v = Virement(date: r.date, montantCentimes: r.montantCentimes, note: r.note)
                v.syncID = r.syncID
                context.insert(v)
            }
            v.date = r.date; v.montantCentimes = r.montantCentimes; v.note = r.note; v.modifiedAt = r.modifiedAt
            changes += 1
        }
        if plafondHebdoModifie.map({ $0 > PactoleReglages.plafondHebdoModifie }) ?? true,
           plafondHebdoCentimes != PactoleReglages.plafondHebdoCentimes {
            PactoleReglages.plafondHebdoCentimes = plafondHebdoCentimes
            PactoleReglages.plafondHebdoModifie = plafondHebdoModifie ?? .now
            changes += 1
        }
        if let tresorerie, let modifie = tresorerieModifie, modifie > PactoleReglages.tresorerieModifie {
            if tresorerie != PactoleReglages.tresorerie { PactoleReglages.tresorerie = tresorerie; changes += 1 }
            PactoleReglages.tresorerieModifie = modifie
        }
        return changes
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> PactoleBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let backup = try decoder.decode(PactoleBackup.self, from: data)
        guard backup.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return backup
    }
}

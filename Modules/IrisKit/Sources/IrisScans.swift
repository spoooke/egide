import Foundation

/// Un scan enregistré : un PDF prêt à joindre au mail.
public struct IrisScan: Identifiable, Hashable, Sendable {
    public var url: URL
    public var date: Date

    public var id: URL { url }
    public var nom: String { url.deletingPathExtension().lastPathComponent }
}

/// Scans rangés sur l'iPhone, dans Documents/Iris (visible dans Fichiers › Sur mon iPhone › Égide).
public struct IrisScans: Sendable {
    public let dossier: URL

    public init(dossier: URL = URL.documentsDirectory.appending(path: "Iris", directoryHint: .isDirectory)) {
        self.dossier = dossier
    }

    /// Scans du plus récent au plus ancien.
    public func liste() -> [IrisScan] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dossier, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "pdf" }
            .map { url in
                IrisScan(url: url, date: (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
            }
            .sorted { ($0.date, $0.nom) > ($1.date, $1.nom) }
    }

    /// Crée le PDF des pages, sous un nom daté libre (« Ticket 2026-10-16 (2) » si besoin).
    /// Le genre vient du choix fait avant le scan, ou du classement d'après le texte lu (IrisClasseur).
    public func enregistrer(_ pages: [IrisPage], genre: IrisGenre, le date: Date = .now) throws -> IrisScan {
        try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        let nom = IrisNom.nom(genre, le: date, pris: Set(liste().map(\.nom)))
        let url = dossier.appending(path: nom + ".pdf")
        try IrisPDF.creer(pages, titre: nom).write(to: url, options: [.atomic, .completeFileProtection])
        return IrisScan(url: url, date: date)
    }

    /// Change le genre d'un scan : « Document 2026-10-16 (2) » devient « Facture 2026-10-16 » (ou « (2) » si
    /// pris). Un PDF partagé, sans genre dans son nom, prend le nom daté du jour où il a été rangé.
    public func changer(_ scan: IrisScan, en genre: IrisGenre, calendrier: Calendar = .current) throws -> IrisScan {
        guard IrisGenre(nom: scan.nom) != genre else { return scan }
        let pris = Set(liste().map(\.nom).filter { $0 != scan.nom })
        var nom = IrisNom.nom(genre, le: scan.date, calendrier: calendrier, pris: pris)
        if let ancien = IrisGenre(nom: scan.nom) {
            // La date du nom est gardée, sans le numéro « (2) » de l'ancien nom.
            var reste = String(scan.nom.dropFirst(ancien.titre.count + 1))
            if let numero = reste.range(of: #" \(\d+\)$"#, options: .regularExpression) { reste.removeSubrange(numero) }
            nom = IrisNom.libre(genre.titre + " " + reste, pris: pris)
        }
        let url = dossier.appending(path: nom + ".pdf")
        try FileManager.default.moveItem(at: scan.url, to: url)
        return IrisScan(url: url, date: scan.date)
    }

    public func supprimer(_ scan: IrisScan) throws {
        try FileManager.default.removeItem(at: scan.url)
    }
}

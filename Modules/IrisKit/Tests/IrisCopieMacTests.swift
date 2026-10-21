import Foundation
import Testing
@testable import IrisKit

/// Dossiers d'essai dans le dossier temporaire : ni iCloud Drive ni les vrais scans ne sont touchés.
@MainActor
struct IrisCopieMacTests {
    private static func dossier() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "iris-mac-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func scan(_ nom: String, dans dossier: URL, contenu: String = "%PDF essai") throws -> IrisScan {
        let url = dossier.appending(path: nom + ".pdf")
        try Data(contenu.utf8).write(to: url)
        return IrisScan(url: url, date: .now)
    }

    private static func stockage() -> UserDefaults {
        let nom = "iris-mac-essai-\(UUID().uuidString)"
        let stockage = UserDefaults(suiteName: nom)!
        stockage.removePersistentDomain(forName: nom)
        return stockage
    }

    /// Fichiers du dossier et de ses sous-dossiers, en chemins relatifs (« Tickets/Ticket 2026-10-17.pdf »).
    private static func noms(_ dossier: URL) throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: dossier.path).filter { chemin in
            var repertoire: ObjCBool = false
            FileManager.default.fileExists(atPath: dossier.appending(path: chemin).path, isDirectory: &repertoire)
            return !repertoire.boolValue
        }.sorted()
    }

    @Test func aucunDossierRienNeSeCopie() async throws {
        let source = try Self.dossier()
        let copie = IrisCopieMac(Self.stockage())
        #expect(copie.nomDossier == nil)
        #expect(await copie.copier([try Self.scan("Ticket 2026-10-17", dans: source)]) == 0)
        #expect(copie.derniereCopie == nil)
    }

    @Test func scanCopieTelQuel() async throws {
        let source = try Self.dossier(), mac = try Self.dossier()
        let copie = IrisCopieMac(Self.stockage())
        try copie.choisir(mac)
        #expect(copie.nomDossier == mac.lastPathComponent)

        let scan = try Self.scan("Ticket 2026-10-17", dans: source, contenu: "%PDF ticket")
        #expect(await copie.copier([scan]) == 1)
        #expect(try Self.noms(mac) == ["Tickets/Ticket 2026-10-17.pdf"])
        #expect(try Data(contentsOf: mac.appending(path: "Tickets/Ticket 2026-10-17.pdf")) == Data("%PDF ticket".utf8))
        #expect(copie.derniereCopie != nil)
        #expect(copie.erreur == nil)
    }

    @Test func nomPrisRecoitUnNumero() async throws {
        let source = try Self.dossier(), mac = try Self.dossier()
        let copie = IrisCopieMac(Self.stockage())
        try copie.choisir(mac)
        let tickets = mac.appending(path: "Tickets")
        try FileManager.default.createDirectory(at: tickets, withIntermediateDirectories: true)
        _ = try Self.scan("Ticket 2026-10-17", dans: tickets, contenu: "%PDF ancien")

        #expect(await copie.copier([try Self.scan("Ticket 2026-10-17", dans: source)]) == 1)
        #expect(try Self.noms(mac) == ["Tickets/Ticket 2026-10-17 (2).pdf", "Tickets/Ticket 2026-10-17.pdf"])
        #expect(try Data(contentsOf: tickets.appending(path: "Ticket 2026-10-17.pdf")) == Data("%PDF ancien".utf8))
    }

    @Test func scansDejaFaitsSansDoublon() async throws {
        let source = try Self.dossier(), mac = try Self.dossier()
        let copie = IrisCopieMac(Self.stockage())
        try copie.choisir(mac)
        let scans = [try Self.scan("Ticket 2026-10-16", dans: source), try Self.scan("Document 2026-10-17", dans: source),
                     try Self.scan("Facture 2026-10-15", dans: source)]
        // Déjà dans iCloud, pas encore téléchargé sur cet iPhone.
        try FileManager.default.createDirectory(at: mac.appending(path: "Tickets"), withIntermediateDirectories: true)
        try Data().write(to: mac.appending(path: "Tickets/.Ticket 2026-10-16.pdf.icloud"))
        // Copié avant les sous-dossiers, à la racine.
        _ = try Self.scan("Facture 2026-10-15", dans: mac)

        #expect(await copie.copier(scans, saufDejaLa: true) == 1)
        #expect(await copie.copier(scans, saufDejaLa: true) == 0)
        #expect(try Self.noms(mac) == ["Documents/Document 2026-10-17.pdf", "Facture 2026-10-15.pdf",
                                       "Tickets/.Ticket 2026-10-16.pdf.icloud"])
    }

    @Test func pdfPartageResteALaRacine() async throws {
        let source = try Self.dossier(), mac = try Self.dossier()
        let copie = IrisCopieMac(Self.stockage())
        try copie.choisir(mac)
        #expect(await copie.copier([try Self.scan("Relevé d'essai", dans: source)]) == 1)
        #expect(try Self.noms(mac) == ["Relevé d'essai.pdf"])
    }

    @Test func genreChangeCopieDeplacee() async throws {
        let source = try Self.dossier(), mac = try Self.dossier()
        let copie = IrisCopieMac(Self.stockage())
        try copie.choisir(mac)
        let ancien = try Self.scan("Document 2026-10-17", dans: source)
        await copie.copier([ancien])
        let nouveau = IrisScan(url: source.appending(path: "Facture 2026-10-17.pdf"), date: ancien.date)
        try FileManager.default.moveItem(at: ancien.url, to: nouveau.url)

        await copie.deplacer(ancien, vers: nouveau)
        #expect(try Self.noms(mac) == ["Factures/Facture 2026-10-17.pdf"])
        #expect(copie.erreur == nil)
    }

    @Test func genreChangeSansCopieAvant() async throws {
        let source = try Self.dossier(), mac = try Self.dossier()
        let copie = IrisCopieMac(Self.stockage())
        let ancien = IrisScan(url: source.appending(path: "Document 2026-10-17.pdf"), date: .now)
        let nouveau = try Self.scan("Ticket 2026-10-17", dans: source)
        // Aucun dossier choisi : rien.
        await copie.deplacer(ancien, vers: nouveau)
        try copie.choisir(mac)
        await copie.deplacer(ancien, vers: nouveau)
        #expect(try Self.noms(mac) == ["Tickets/Ticket 2026-10-17.pdf"])
    }

    @Test func dossierDisparuErreurNotee() async throws {
        let source = try Self.dossier(), mac = try Self.dossier()
        let copie = IrisCopieMac(Self.stockage())
        try copie.choisir(mac)
        try FileManager.default.removeItem(at: mac)

        #expect(await copie.copier([try Self.scan("Ticket 2026-10-17", dans: source)]) == 0)
        #expect(copie.erreur?.hasPrefix("Copie impossible") == true)

        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        #expect(await copie.copier([try Self.scan("Ticket 2026-10-18", dans: source)]) == 1)
        #expect(copie.erreur == nil)
    }

    @Test func arreterOublieLeDossier() async throws {
        let source = try Self.dossier(), mac = try Self.dossier()
        let copie = IrisCopieMac(Self.stockage())
        try copie.choisir(mac)
        copie.arreter()
        #expect(copie.nomDossier == nil)
        #expect(await copie.copier([try Self.scan("Ticket 2026-10-17", dans: source)]) == 0)
        #expect(try Self.noms(mac).isEmpty)
    }

    @Test func signetHorsDeLaSauvegarde() throws {
        let mac = try Self.dossier()
        let stockage = Self.stockage()
        try IrisCopieMac(stockage).choisir(mac)
        // Les réglages (sauvegarde globale) ne portent pas le dossier : il ne vaut que pour cet iPhone.
        let json = String(decoding: try JSONEncoder().encode(IrisReglages.charger(stockage)), as: UTF8.self)
        #expect(!json.contains(mac.lastPathComponent))
    }
}

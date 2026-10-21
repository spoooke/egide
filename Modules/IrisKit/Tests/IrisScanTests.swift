import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import IrisKit

/// Scans fabriqués par les tests : une feuille blanche avec du texte noir, rien de réel.
struct IrisScanTests {
    private static func feuille(largeur: Int = 1240, hauteur: Int = 1754, lignes: [String] = []) -> CGImage {
        let contexte = CGContext(data: nil, width: largeur, height: hauteur, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        contexte.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        contexte.fill(CGRect(x: 0, y: 0, width: largeur, height: hauteur))
        let police = CTFontCreateWithName("Helvetica-Bold" as CFString, 90, nil)
        for (index, ligne) in lignes.enumerated() {
            let texte = NSAttributedString(string: ligne, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: police,
                kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            ])
            contexte.textPosition = CGPoint(x: 100, y: hauteur - 250 - index * 160)
            CTLineDraw(CTLineCreateWithAttributedString(texte), contexte)
        }
        return contexte.makeImage()!
    }

    private static func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    // MARK: Nommage

    @Test func nomDate() {
        var calendrier = Calendar(identifier: .gregorian)
        calendrier.timeZone = TimeZone(identifier: "Europe/Paris")!
        let date = calendrier.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 23, minute: 30))!
        #expect(IrisNom.nom(.ticket, le: date, calendrier: calendrier) == "Ticket 2026-10-06")
        #expect(IrisNom.nom(.document, le: date, calendrier: calendrier) == "Document 2026-10-06")
    }

    @Test func nomDejaPris() {
        let calendrier = Calendar(identifier: .gregorian)
        let date = calendrier.date(from: DateComponents(year: 2026, month: 1, day: 2))!
        #expect(IrisNom.nom(.ticket, le: date, calendrier: calendrier, pris: ["Ticket 2026-01-02"]) == "Ticket 2026-01-02 (2)")
        #expect(IrisNom.nom(.ticket, le: date, calendrier: calendrier,
                            pris: ["ticket 2026-01-02", "Ticket 2026-01-02 (2)"]) == "Ticket 2026-01-02 (3)")
        #expect(IrisNom.nom(.document, le: date, calendrier: calendrier, pris: ["Ticket 2026-01-02"]) == "Document 2026-01-02")
    }

    // MARK: Compression

    @Test func imageReduite() throws {
        let grande = Self.png(Self.feuille(largeur: 3000, hauteur: 4000))
        let image = try IrisImage.image(de: grande)
        #expect(max(image.width, image.height) == IrisImage.coteMax)
        #expect(image.width * 4 == image.height * 3)
        // Une petite image n'est pas agrandie.
        let petite = try IrisImage.image(de: Self.png(Self.feuille(largeur: 300, hauteur: 400)))
        #expect(petite.width == 300 && petite.height == 400)
    }

    @Test func imageIllisible() {
        #expect(throws: IrisErreur.self) { try IrisImage.image(de: Data("pas une image".utf8)) }
    }

    @Test func pdfLeger() throws {
        let image = try IrisImage.image(de: Self.png(Self.feuille(largeur: 3000, hauteur: 4000, lignes: ["TOTAL 12,50"])))
        let jpeg = try IrisImage.jpeg(image)
        let page = IrisPage(jpeg: jpeg, largeur: image.width, hauteur: image.height, lignes: [])
        let pdf = try IrisPDF.creer([page, page], titre: "Essai")
        // Le JPEG est repris tel quel : le PDF pèse à peu près ses images.
        #expect(pdf.count < jpeg.count * 2 + 20_000)
        #expect(pdf.count < 1_000_000)
        let document = try #require(PDFDocument(data: pdf))
        #expect(document.pageCount == 2)
        let boite = try #require(document.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(boite.height - IrisPDF.coteMaxPoints) < 1)
        #expect(abs(boite.width - IrisPDF.coteMaxPoints * 0.75) < 1)
    }

    // MARK: PDF où l'on peut chercher

    @Test func pdfCherchable() throws {
        let image = Self.feuille(largeur: 600, hauteur: 800)
        let lignes = [
            IrisLigne(texte: "Boulangerie du Port", boite: CGRect(x: 0.1, y: 0.8, width: 0.6, height: 0.05)),
            IrisLigne(texte: "TOTAL 12,50 €", boite: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.04)),
        ]
        let page = IrisPage(jpeg: try IrisImage.jpeg(image), largeur: 600, hauteur: 800, lignes: lignes)
        let document = try #require(PDFDocument(data: try IrisPDF.creer([page], titre: "Ticket 2026-10-16")))
        let texte = try #require(document.string)
        #expect(texte.contains("Boulangerie du Port"))
        #expect(texte.contains("TOTAL 12,50 €"))
        #expect(!document.findString("12,50", withOptions: []).isEmpty)
        #expect(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Ticket 2026-10-16")
        // Le texte est posé à l'endroit de la ligne lue (en haut de la page pour la première).
        let selection = try #require(document.findString("Boulangerie", withOptions: []).first)
        let pagePDF = try #require(document.page(at: 0))
        #expect(selection.bounds(for: pagePDF).midY > pagePDF.bounds(for: .mediaBox).height * 0.7)
    }

    @Test func pdfVide() {
        #expect(throws: IrisErreur.self) { try IrisPDF.creer([], titre: "Rien") }
    }

    /// De bout en bout : image → texte lu par Vision → PDF où l'on retrouve ce texte.
    @Test func lectureDuTexte() async throws {
        let data = Self.png(Self.feuille(lignes: ["IRIS SCAN", "TOTAL 42"]))
        let page = try await IrisImage.page(de: data)
        let lu = page.lignes.map(\.texte).joined(separator: " ").uppercased()
        #expect(lu.contains("IRIS"))
        #expect(lu.contains("42"))
        let document = try #require(PDFDocument(data: try IrisPDF.creer([page], titre: "Essai")))
        #expect(!document.findString("42", withOptions: []).isEmpty)
    }

    // MARK: Rangement

    @Test func rangement() throws {
        let dossier = FileManager.default.temporaryDirectory.appending(path: "IrisScanTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dossier) }
        let scans = IrisScans(dossier: dossier)
        #expect(scans.liste().isEmpty)
        let image = Self.feuille(largeur: 200, hauteur: 300)
        let page = IrisPage(jpeg: try IrisImage.jpeg(image), largeur: 200, hauteur: 300, lignes: [])
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 12))!
        let premier = try scans.enregistrer([page], genre: .ticket, le: date)
        let second = try scans.enregistrer([page], genre: .ticket, le: date)
        #expect(premier.nom == "Ticket 2026-10-16")
        #expect(second.nom == "Ticket 2026-10-16 (2)")
        #expect(Set(scans.liste().map(\.nom)) == [premier.nom, second.nom])
        try scans.supprimer(premier)
        #expect(scans.liste().map(\.nom) == [second.nom])
    }

    @Test func changerDeGenre() throws {
        let dossier = FileManager.default.temporaryDirectory.appending(path: "IrisScanTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dossier) }
        let scans = IrisScans(dossier: dossier)
        let page = IrisPage(jpeg: try IrisImage.jpeg(Self.feuille(largeur: 200, hauteur: 300)), largeur: 200, hauteur: 300, lignes: [])
        var calendrier = Calendar(identifier: .gregorian)
        calendrier.timeZone = TimeZone(identifier: "Europe/Paris")!
        let date = calendrier.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 12))!
        _ = try scans.enregistrer([page], genre: .facture, le: date)
        _ = try scans.enregistrer([page], genre: .document, le: date)
        let second = try scans.enregistrer([page], genre: .document, le: date)
        #expect(second.nom == "Document 2026-10-16 (2)")

        // Le numéro de l'ancien nom tombe ; « (2) » revient si le nom est pris.
        let facture = try scans.changer(second, en: .facture, calendrier: calendrier)
        #expect(facture.nom == "Facture 2026-10-16 (2)")
        let ticket = try scans.changer(facture, en: .ticket, calendrier: calendrier)
        #expect(ticket.nom == "Ticket 2026-10-16")
        #expect(try scans.changer(ticket, en: .ticket, calendrier: calendrier) == ticket)
        #expect(Set(scans.liste().map(\.nom)) == ["Facture 2026-10-16", "Document 2026-10-16", "Ticket 2026-10-16"])

        // PDF partagé gardé sous son nom : il prend le nom daté.
        let partage = try scans.ranger(IrisFichierPartage(type: UTType.pdf.identifier, nom: "Relevé d'essai.pdf", data: try IrisPDF.creer([page], titre: "essai")), le: date)
        #expect(try scans.changer(partage, en: .document, calendrier: calendrier).nom == "Document 2026-10-16 (2)")
    }

    @Test func genreDuNom() {
        #expect(IrisGenre(nom: "Facture 2026-10-17 (2)") == .facture)
        #expect(IrisGenre(nom: "ticket 2026-10-17") == .ticket)
        #expect(IrisGenre(nom: "Tickets de métro") == nil)
        #expect(IrisGenre(nom: "Relevé d'essai") == nil)
        #expect(IrisGenre.facture.dossier == "Factures")
    }

    @Test func nombreDePages() throws {
        let dossier = FileManager.default.temporaryDirectory.appending(path: "IrisScanTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dossier) }
        let page = IrisPage(jpeg: try IrisImage.jpeg(Self.feuille(largeur: 200, hauteur: 300)), largeur: 200, hauteur: 300, lignes: [])
        let scan = try IrisScans(dossier: dossier).enregistrer([page, page, page], genre: .document)
        #expect(scan.pages == 3)
    }
}

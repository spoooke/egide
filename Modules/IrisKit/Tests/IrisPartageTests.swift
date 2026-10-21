import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import IrisKit

/// Photothèque d'essai : garde ce qu'on lui donne, la vraie photothèque n'est jamais touchée.
private actor PhotothequeEssai: IrisPhototheque {
    private(set) var ajouts: [[Data]] = []
    let accepte: Bool

    init(accepte: Bool = true) { self.accepte = accepte }

    func ajouter(_ jpegs: [Data]) async -> Bool {
        guard accepte else { return false }
        ajouts.append(jpegs)
        return true
    }
}

struct IrisPartageTests {
    private static func page() -> IrisPage {
        IrisPage(jpeg: Data([0xFF, 0xD8, 0xFF]), largeur: 10, hauteur: 10, lignes: [])
    }

    /// Un petit PDF d'une page, fabriqué ici.
    private static func pdf() -> Data {
        let data = NSMutableData()
        var boite = CGRect(x: 0, y: 0, width: 100, height: 100)
        let contexte = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &boite, nil)!
        contexte.beginPage(mediaBox: &boite)
        contexte.endPage()
        contexte.closePDF()
        return data as Data
    }

    private static func png() -> Data {
        let contexte = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, contexte.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private static func dossier() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "IrisPartage-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    // MARK: Photos

    @Test func photosSiActif() async {
        let phototheque = PhotothequeEssai()
        let reglages = IrisReglages(destinataires: ["a@example.com"], garderDansPhotos: true)
        #expect(await IrisCopiePhotos.copier([Self.page(), Self.page()], reglages: reglages, dans: phototheque))
        #expect(await phototheque.ajouts.map(\.count) == [2])
    }

    @Test func rienDansPhotosSiEteint() async {
        let phototheque = PhotothequeEssai()
        let reglages = IrisReglages(destinataires: ["a@example.com"], garderDansPhotos: false)
        #expect(!(await IrisCopiePhotos.copier([Self.page()], reglages: reglages, dans: phototheque)))
        #expect(await phototheque.ajouts.isEmpty)
    }

    @Test func photosRefusees() async {
        let reglages = IrisReglages(garderDansPhotos: true)
        #expect(!(await IrisCopiePhotos.copier([Self.page()], reglages: reglages, dans: PhotothequeEssai(accepte: false))))
    }

    @Test func reglageGardeEnregistre() throws {
        let stockage = try #require(UserDefaults(suiteName: "IrisPartageTests-\(UUID().uuidString)"))
        IrisReglages(destinataires: ["a@example.com"], garderDansPhotos: true).enregistrer(stockage)
        #expect(IrisReglages.charger(stockage).garderDansPhotos)
        #expect(!IrisReglages().garderDansPhotos)
    }

    // MARK: Routage

    @Test func routage() {
        #expect(IrisPartage.destination(IrisFichierPartage(type: UTType.png.identifier, nom: "IMG_0001", data: Self.png())) == .cadrage)
        #expect(IrisPartage.destination(IrisFichierPartage(type: UTType.heic.identifier, nom: "IMG_0002", data: Data([1]))) == .cadrage)
        #expect(IrisPartage.destination(IrisFichierPartage(type: UTType.pdf.identifier, nom: "Facture.pdf", data: Self.pdf())) == .rangement)
    }

    @Test func refus() {
        // Autre type, PDF abîmé, fichier vide (trop gros pour l'extension) ou type inconnu.
        #expect(IrisPartage.destination(IrisFichierPartage(type: "org.openxmlformats.wordprocessingml.document", nom: "Lettre.docx", data: Data([1]))) == .refus)
        #expect(IrisPartage.destination(IrisFichierPartage(type: UTType.pdf.identifier, nom: "Abîmé.pdf", data: Data("pas un pdf".utf8))) == .refus)
        #expect(IrisPartage.destination(IrisFichierPartage(type: UTType.jpeg.identifier, nom: "Vide", data: Data())) == .refus)
        #expect(IrisPartage.destination(IrisFichierPartage(type: "", nom: "", data: Data([1]))) == .refus)
    }

    @Test func tri() {
        let tri = IrisPartage.trier([
            IrisFichierPartage(type: UTType.pdf.identifier, nom: "Facture.pdf", data: Self.pdf()),
            IrisFichierPartage(type: UTType.png.identifier, nom: "IMG_0001", data: Self.png()),
            IrisFichierPartage(type: UTType.zip.identifier, nom: "Archive.zip", data: Data([1])),
            IrisFichierPartage(type: UTType.zip.identifier, nom: "", data: Data([1])),
        ])
        #expect(tri.images.count == 1)
        #expect(tri.pdfs.map(\.nom) == ["Facture.pdf"])
        #expect(tri.refuses == ["Archive.zip", "Fichier sans nom"])
    }

    // MARK: Passage par le trousseau

    @Test func colis() throws {
        let fichiers = [
            IrisFichierPartage(type: UTType.pdf.identifier, nom: "Facture.pdf", data: Self.pdf()),
            IrisFichierPartage(type: UTType.png.identifier, nom: "IMG_0001", data: Self.png()),
        ]
        let paquet = try IrisColis.paquet(fichiers)
        let morceaux = IrisColis.morceaux(paquet, taille: 1000)
        #expect(morceaux.count == (paquet.count + 999) / 1000)
        #expect(try IrisColis.fichiers(Data(morceaux.joined())) == fichiers)
    }

    @Test func colisTropGros() throws {
        let gros = IrisFichierPartage(type: UTType.jpeg.identifier, nom: "Gros", data: Data(count: IrisColis.tailleMax + 1))
        let recu = try IrisColis.fichiers(IrisColis.paquet([gros]))
        #expect(recu.map(\.nom) == ["Gros"])
        #expect(recu.first?.data.isEmpty == true)
        #expect(IrisPartage.trier(recu).refuses == ["Gros"])
        let nombreux = Array(repeating: IrisFichierPartage(type: UTType.png.identifier, nom: "IMG", data: Data([1])), count: 30)
        #expect(try IrisColis.fichiers(IrisColis.paquet(nombreux)).count == IrisColis.nombreMax)
    }

    @Test func photoReduite() throws {
        let contexte = CGContext(data: nil, width: 4000, height: 3000, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        // Photo d'essai avec un lieu fictif : il ne doit pas rester.
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 48.0, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 2.0, kCGImagePropertyGPSLongitudeRef: "E"]
        CGImageDestinationAddImage(destination, contexte.makeImage()!, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        CGImageDestinationFinalize(destination)
        let reduite = try #require(IrisColis.reduire(data as Data))
        let source = try #require(CGImageSourceCreateWithData(reduite as CFData, nil))
        let proprietes = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(proprietes[kCGImagePropertyPixelWidth] as? Int == IrisColis.coteImage)
        #expect(proprietes[kCGImagePropertyGPSDictionary] == nil)
    }

    // MARK: PDF partagé

    @Test func nomDuPDFPartage() {
        let calendrier = Calendar(identifier: .gregorian)
        let date = calendrier.date(from: DateComponents(year: 2026, month: 10, day: 16))!
        #expect(IrisNom.partage("Facture EDF.pdf", le: date, calendrier: calendrier) == "Facture EDF")
        #expect(IrisNom.partage("Facture EDF.PDF", le: date, calendrier: calendrier, pris: ["facture edf"]) == "Facture EDF (2)")
        #expect(IrisNom.partage("a/b:c\nd.pdf", le: date, calendrier: calendrier) == "a b c d")
        #expect(IrisNom.partage("..cache.pdf", le: date, calendrier: calendrier) == "cache")
        #expect(IrisNom.partage("", le: date, calendrier: calendrier) == "Document 2026-10-16")
        #expect(IrisNom.partage(" .pdf", le: date, calendrier: calendrier, pris: ["Document 2026-10-16"]) == "Document 2026-10-16 (2)")
        #expect(IrisNom.partage(String(repeating: "x", count: 200), le: date, calendrier: calendrier).count == 80)
    }

    @Test func pdfRangeTelQuel() throws {
        let dossier = Self.dossier()
        defer { try? FileManager.default.removeItem(at: dossier) }
        let scans = IrisScans(dossier: dossier)
        let pdf = Self.pdf()
        let scan = try scans.ranger(IrisFichierPartage(type: UTType.pdf.identifier, nom: "Facture.pdf", data: pdf))
        #expect(scan.nom == "Facture")
        #expect(try Data(contentsOf: scan.url) == pdf)
        let second = try scans.ranger(IrisFichierPartage(type: UTType.pdf.identifier, nom: "Facture.pdf", data: pdf))
        #expect(second.nom == "Facture (2)")
        #expect(scans.liste().count == 2)
        #expect(throws: IrisErreur.self) {
            try scans.ranger(IrisFichierPartage(type: UTType.pdf.identifier, nom: "Abîmé.pdf", data: Data("non".utf8)))
        }
    }

    @Test func routeDuLien() {
        #expect(IrisRoute(path: ["partage"]) == .partage)
        #expect(IrisColis.lien.absoluteString == "egide://iris/partage")
    }
}

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Genre du scan, qui donne son nom au PDF.
public enum IrisGenre: String, CaseIterable, Codable, Sendable {
    case ticket, facture, document

    public var titre: String {
        switch self {
        case .ticket: "Ticket"
        case .facture: "Facture"
        case .document: "Document"
        }
    }

    /// Sous-dossier de la copie pour le Mac.
    public var dossier: String { titre + "s" }

    /// Genre d'un nom de scan (« Facture 2026-10-17 (2) ») ; nil pour un PDF partagé gardé sous son nom.
    public init?(nom: String) {
        guard let genre = Self.allCases.first(where: { nom.lowercased().hasPrefix($0.titre.lowercased() + " ") }) else { return nil }
        self = genre
    }
}

/// Nom du scan : « Ticket 2026-10-16 », puis « Ticket 2026-10-16 (2) » si le nom est déjà pris.
public enum IrisNom {
    public static func nom(_ genre: IrisGenre, le date: Date, calendrier: Calendar = .current, pris: Set<String> = []) -> String {
        let c = calendrier.dateComponents([.year, .month, .day], from: date)
        return libre(String(format: "%@ %04d-%02d-%02d", genre.titre, c.year ?? 0, c.month ?? 0, c.day ?? 0), pris: pris)
    }

    /// `base`, ou « base (2) », « base (3) »… s'il est déjà pris (sans tenir compte des majuscules).
    static func libre(_ base: String, pris: Set<String>) -> String {
        let dejaPris = Set(pris.map { $0.lowercased() })
        var nom = base, numero = 2
        while dejaPris.contains(nom.lowercased()) {
            nom = "\(base) (\(numero))"
            numero += 1
        }
        return nom
    }
}

/// Une ligne de texte reconnue : `boite` en coordonnées normalisées (0…1, origine en bas à gauche, comme Vision).
public struct IrisLigne: Equatable, Sendable {
    public var texte: String
    public var boite: CGRect

    public init(texte: String, boite: CGRect) {
        self.texte = texte
        self.boite = boite
    }
}

/// Une page du PDF : l'image compressée (JPEG) et le texte lu dessus.
public struct IrisPage: Sendable {
    public var jpeg: Data
    public var largeur: Int
    public var hauteur: Int
    public var lignes: [IrisLigne]
}

public enum IrisErreur: LocalizedError {
    case imageIllisible
    case pdfImpossible

    public var errorDescription: String? {
        switch self {
        case .imageIllisible: "Cette image ne peut pas être lue."
        case .pdfImpossible: "Le PDF n'a pas pu être créé."
        }
    }
}

/// Préparation des pages : image remise à l'endroit, réduite, compressée ; texte lu sur l'iPhone.
public enum IrisImage {
    /// Plus grand côté gardé : assez pour lire un ticket, assez petit pour un mail léger.
    public static let coteMax = 2000
    public static let qualiteJPEG = 0.6

    /// Image à l'endroit (orientation EXIF appliquée), réduite à `coteMax` pixels au plus.
    public static func image(de data: Data, coteMax: Int = coteMax) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw IrisErreur.imageIllisible }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: coteMax,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw IrisErreur.imageIllisible }
        return image
    }

    /// Image compressée en JPEG.
    public static func jpeg(_ image: CGImage, qualite: Double = qualiteJPEG) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw IrisErreur.imageIllisible
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: qualite] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw IrisErreur.imageIllisible }
        return data as Data
    }

    /// Lignes de texte lues sur l'image, sur l'iPhone (rien n'est envoyé).
    public static func texte(_ image: CGImage) async throws -> [IrisLigne] {
        var requete = RecognizeTextRequest()
        requete.recognitionLanguages = [Locale.Language(identifier: "fr-FR"), Locale.Language(identifier: "en-US")]
        requete.usesLanguageCorrection = true
        return try await requete.perform(on: image).compactMap { observation in
            guard let texte = observation.topCandidates(1).first?.string, !texte.isEmpty else { return nil }
            return IrisLigne(texte: texte, boite: observation.boundingBox.cgRect)
        }
    }

    /// Page prête pour le PDF, à partir d'une photo (JPEG, HEIC, PNG…).
    public static func page(de data: Data) async throws -> IrisPage {
        try await page(de: try image(de: data))
    }

    /// Page prête pour le PDF, à partir d'une image déjà lue (et redressée au besoin).
    public static func page(de image: CGImage) async throws -> IrisPage {
        let lignes = try await texte(image)
        return IrisPage(jpeg: try jpeg(image), largeur: image.width, hauteur: image.height, lignes: lignes)
    }
}

/// PDF léger où l'on peut chercher : une page par image, le texte lu posé dessus, invisible.
public enum IrisPDF {
    /// Plus grand côté d'une page, en points (celui d'une feuille A4).
    public static let coteMaxPoints = 842.0

    public static func creer(_ pages: [IrisPage], titre: String) throws -> Data {
        let data = NSMutableData()
        let infos: [CFString: Any] = [kCGPDFContextTitle: titre, kCGPDFContextCreator: "Iris"]
        guard !pages.isEmpty, let consommateur = CGDataConsumer(data: data),
              let contexte = CGContext(consumer: consommateur, mediaBox: nil, infos as CFDictionary) else {
            throw IrisErreur.pdfImpossible
        }
        for page in pages {
            // L'image JPEG est reprise telle quelle dans le PDF (pas recompressée).
            guard let fournisseur = CGDataProvider(data: page.jpeg as CFData),
                  let image = CGImage(jpegDataProviderSource: fournisseur, decode: nil, shouldInterpolate: true,
                                      intent: .defaultIntent) else { throw IrisErreur.pdfImpossible }
            let echelle = coteMaxPoints / Double(max(page.largeur, page.hauteur))
            var boite = CGRect(x: 0, y: 0, width: Double(page.largeur) * echelle, height: Double(page.hauteur) * echelle)
            contexte.beginPage(mediaBox: &boite)
            contexte.draw(image, in: boite)
            poserTexte(page.lignes, sur: boite, dans: contexte)
            contexte.endPage()
        }
        contexte.closePDF()
        return data as Data
    }

    /// Texte invisible à l'emplacement de chaque ligne, étiré à sa largeur : on le cherche et on le copie.
    private static func poserTexte(_ lignes: [IrisLigne], sur page: CGRect, dans contexte: CGContext) {
        contexte.saveGState()
        contexte.setTextDrawingMode(.invisible)
        for ligne in lignes {
            let boite = CGRect(x: ligne.boite.minX * page.width, y: ligne.boite.minY * page.height,
                               width: ligne.boite.width * page.width, height: ligne.boite.height * page.height)
            guard boite.width > 0, boite.height > 0 else { continue }
            let police = CTFontCreateWithName("Helvetica" as CFString, boite.height * 0.8, nil)
            let texte = NSAttributedString(string: ligne.texte, attributes: [kCTFontAttributeName as NSAttributedString.Key: police])
            let rendu = CTLineCreateWithAttributedString(texte)
            let largeur = CTLineGetTypographicBounds(rendu, nil, nil, nil)
            guard largeur > 0 else { continue }
            contexte.textMatrix = CGAffineTransform(scaleX: boite.width / largeur, y: 1)
            contexte.textPosition = CGPoint(x: boite.minX, y: boite.minY + boite.height * 0.2)
            CTLineDraw(rendu, contexte)
        }
        contexte.restoreGState()
    }
}

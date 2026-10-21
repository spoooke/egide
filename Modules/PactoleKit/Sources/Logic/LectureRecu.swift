import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Texte d'un reçu : PDF (texte, ou lecture de l'image s'il est scanné), image ou capture (lecture du texte
/// sur l'appareil, rien n'est envoyé), texte, HTML ou mail (.eml).
enum LectureRecu {
    enum Erreur: LocalizedError {
        case illisible

        var errorDescription: String? { "Aucun texte trouvé sur ce reçu." }
    }

    static func texte(de url: URL) async throws -> String {
        let type = UTType(filenameExtension: url.pathExtension.lowercased()) ?? .data
        let data = try Data(contentsOf: url)
        return try await texte(de: data, type: type)
    }

    static func texte(de data: Data, type: UTType) async throws -> String {
        let texte: String
        if type.conforms(to: .pdf) {
            texte = try await textePDF(data)
        } else if type.conforms(to: .image) {
            guard let image = CGImageSourceCreateWithData(data as CFData, nil)
                .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else { throw Erreur.illisible }
            texte = try await ocr(image)
        } else {
            texte = texteBrut(String(decoding: data, as: UTF8.self))
        }
        guard !texte.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Erreur.illisible }
        return texte
    }

    private static func textePDF(_ data: Data) async throws -> String {
        guard let pdf = PDFDocument(data: data) else { throw Erreur.illisible }
        if let texte = pdf.string, texte.contains(where: \.isNumber) { return texte }
        // PDF scanné : lecture de l'image des deux premières pages.
        var lignes: [String] = []
        for index in 0..<min(pdf.pageCount, 2) {
            guard let page = pdf.page(at: index), let image = rendu(page) else { continue }
            lignes.append(try await ocr(image))
        }
        return lignes.joined(separator: "\n")
    }

    private static func rendu(_ page: PDFPage) -> CGImage? {
        let boite = page.bounds(for: .mediaBox)
        let echelle = 2.0
        let largeur = Int(boite.width * echelle), hauteur = Int(boite.height * echelle)
        guard let contexte = CGContext(data: nil, width: largeur, height: hauteur, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        contexte.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        contexte.fill(CGRect(x: 0, y: 0, width: largeur, height: hauteur))
        contexte.scaleBy(x: echelle, y: echelle)
        page.draw(with: .mediaBox, to: contexte)
        return contexte.makeImage()
    }

    /// Lecture du texte de l'image, ligne par ligne : les morceaux à la même hauteur (« Total » à gauche,
    /// « 57,49 € » à droite) sont remis sur une seule ligne.
    private static func ocr(_ image: CGImage) async throws -> String {
        var requete = RecognizeTextRequest()
        requete.recognitionLanguages = [Locale.Language(identifier: "fr-FR"), Locale.Language(identifier: "en-US")]
        requete.usesLanguageCorrection = true
        let observations = try await requete.perform(on: image)
        let morceaux = observations.compactMap { obs -> (y: CGFloat, x: CGFloat, h: CGFloat, texte: String)? in
            guard let texte = obs.topCandidates(1).first?.string else { return nil }
            let boite = obs.boundingBox.cgRect
            return (boite.midY, boite.minX, boite.height, texte)
        }
        var lignes: [[(y: CGFloat, x: CGFloat, h: CGFloat, texte: String)]] = []
        for morceau in morceaux.sorted(by: { $0.y > $1.y }) {
            if let derniere = lignes.last?.first, abs(derniere.y - morceau.y) < max(derniere.h, morceau.h) / 2 {
                lignes[lignes.count - 1].append(morceau)
            } else {
                lignes.append([morceau])
            }
        }
        return lignes.map { $0.sorted { $0.x < $1.x }.map(\.texte).joined(separator: " ") }.joined(separator: "\n")
    }

    /// Texte d'un mail (.eml, quoted-printable) ou d'une page HTML, sans balises.
    static func texteBrut(_ brut: String) -> String {
        var texte = brut
        if texte.contains("=\r\n") || texte.contains("=\n") || texte.range(of: "=[0-9A-F]{2}", options: .regularExpression) != nil {
            texte = quotedPrintable(texte)
        }
        if texte.range(of: "<(html|body|div|td|p|br)", options: [.regularExpression, .caseInsensitive]) != nil {
            texte = texte.replacingOccurrences(of: "(?is)<(style|script)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "(?i)<(br|/p|/div|/tr|/h\\d|/li)[^>]*>", with: "\n", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&euro;", with: "€")
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#8364;", with: "€")
                .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&rsquo;", with: "’")
        }
        return texte.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func quotedPrintable(_ texte: String) -> String {
        let joint = texte.replacingOccurrences(of: "=\r\n", with: "").replacingOccurrences(of: "=\n", with: "")
        var octets: [UInt8] = []
        var index = joint.utf8.startIndex
        let utf8 = joint.utf8
        while index < utf8.endIndex {
            let octet = utf8[index]
            if octet == UInt8(ascii: "="),
               let a = utf8.index(index, offsetBy: 1, limitedBy: utf8.endIndex), a < utf8.endIndex,
               let b = utf8.index(index, offsetBy: 2, limitedBy: utf8.endIndex), b < utf8.endIndex,
               let valeur = UInt8(String(decoding: [utf8[a], utf8[b]], as: UTF8.self), radix: 16) {
                octets.append(valeur)
                index = utf8.index(after: b)
            } else {
                octets.append(octet)
                index = utf8.index(after: index)
            }
        }
        return String(decoding: octets, as: UTF8.self)
    }
}

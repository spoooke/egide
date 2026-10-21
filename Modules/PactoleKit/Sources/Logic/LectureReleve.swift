import Foundation
import PDFKit

/// Lecture par position d'un relevé PDF (PDFKit) : morceaux de texte de chaque ligne avec leur abscisse,
/// regroupés par hauteur puis triés de gauche à droite. Le texte brut de la page mélange les colonnes.
enum LectureReleve {
    /// Vrai pour un PDF de « RELEVÉ DE COMPTE » avec les colonnes « Débit » et « Crédit ».
    static func estUnReleve(_ data: Data) -> Bool {
        guard let texte = PDFDocument(data: data)?.page(at: 0)?.string else { return false }
        let n = Classement.normaliser(texte)
        return n.contains("releve de compte") && n.contains("debit") && n.contains("credit")
    }

    static func lire(_ data: Data) throws -> Releve {
        try Releve.analyser(pages(data))
    }

    static func pages(_ data: Data) throws -> [PageReleve] {
        guard let pdf = PDFDocument(data: data) else { throw Releve.Erreur.pasUnReleve }
        return (0..<pdf.pageCount).compactMap { pdf.page(at: $0) }.map(page)
    }

    private static func page(_ page: PDFPage) -> PageReleve {
        let boite = page.bounds(for: .mediaBox)
        let morceaux: [(y: Double, morceau: MorceauReleve)] = (page.selection(for: boite)?.selectionsByLine() ?? [])
            .compactMap { selection in
                let b = selection.bounds(for: page)
                let texte = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                // Texte vertical de la marge : plus haut que large.
                guard !texte.isEmpty, b.height < 20 else { return nil }
                return (b.midY, MorceauReleve(debut: b.minX, fin: b.maxX, texte: texte))
            }
            .sorted { $0.y > $1.y }
        var lignes: [(y: Double, morceaux: [MorceauReleve])] = []
        for (y, morceau) in morceaux {
            if let derniere = lignes.last, abs(derniere.y - y) < 2.5 {
                lignes[lignes.count - 1].morceaux.append(morceau)
            } else {
                lignes.append((y, [morceau]))
            }
        }
        return PageReleve(lignes: lignes.map { LigneReleve(morceaux: $0.morceaux.sorted { $0.debut < $1.debut }) },
                          colonnes: colonnes(page))
    }

    /// Milieu des titres « Débit » et « Crédit » de l'en-tête du tableau.
    private static func colonnes(_ page: PDFPage) -> PageReleve.Colonnes? {
        guard let texte = page.string as NSString? else { return nil }
        let debit = texte.range(of: "Débit")
        guard debit.location != NSNotFound else { return nil }
        let credit = texte.range(of: "Crédit", range: NSRange(location: debit.location, length: texte.length - debit.location))
        guard credit.location != NSNotFound,
              let debit = page.selection(for: debit)?.bounds(for: page),
              let credit = page.selection(for: credit)?.bounds(for: page) else { return nil }
        return PageReleve.Colonnes(debit: debit.midX, credit: credit.midX)
    }
}

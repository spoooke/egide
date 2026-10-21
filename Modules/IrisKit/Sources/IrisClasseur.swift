import Foundation

/// Choix du genre avant le scan : Auto (reconnu d'après le texte lu) ou un genre forcé.
public enum IrisChoixGenre: String, CaseIterable, Sendable {
    case auto, ticket, facture, document

    public var titre: String { genre?.titre ?? "Auto" }

    public var genre: IrisGenre? { IrisGenre(rawValue: rawValue) }
}

/// Classement d'un scan en ticket, facture ou document, d'après le texte déjà lu par Vision et la forme
/// des pages. Tout se fait sur l'iPhone. Chaque genre compte ses indices ; il faut assez de points et une
/// avance nette, sinon le classement hésite (nil) et le scan reste un document.
public enum IrisClasseur {
    /// Points minimum pour un ticket ou une facture.
    static let seuil = 4
    /// Avance minimum sur l'autre genre.
    static let ecart = 2

    public static func genre(_ pages: [IrisPage]) -> IrisGenre? {
        let points = self.points(pages)
        let (gagnant, perdant) = points.ticket >= points.facture ? (IrisGenre.ticket, points.facture) : (.facture, points.ticket)
        let meilleur = max(points.ticket, points.facture)
        return meilleur >= seuil && meilleur - perdant >= ecart ? gagnant : nil
    }

    /// Genre à donner au scan : le choix forcé, sinon le classement, sinon Document.
    public static func genre(_ pages: [IrisPage], choix: IrisChoixGenre) -> IrisGenre {
        choix.genre ?? genre(pages) ?? .document
    }

    static func points(_ pages: [IrisPage]) -> (ticket: Int, facture: Int) {
        let lignes = pages.flatMap(\.lignes).map { normaliser($0.texte) }
        let texte = lignes.joined(separator: "\n")
        func a(_ motif: String) -> Bool { texte.range(of: motif, options: .regularExpression) != nil }

        var facture = 0
        if a(#"\b(facture|invoice)\b"#) { facture += 3 }
        if a(#"\b(n|no|numero|num)\b\W{0,3}(de )?facture|facture\W{0,3}(n|no)\b|invoice (n|no|number)\b"#) { facture += 2 }
        if a(#"\b(total|montant|prix|sous-total) (net )?h\.?t\b|\bhors taxes?\b"#) { facture += 2 }
        if a(#"\btva intra|\bfr ?[0-9a-z]{2} ?\d{3} ?\d{3} ?\d{3}\b"#) { facture += 1 }
        if a(#"\b(echeance|conditions de (paiement|reglement)|iban|bic|adresse de facturation|date de facture)\b"#) { facture += 2 }
        if a(#"\b(siret|siren|rcs|ape|naf)\b"#) { facture += 1 }

        var ticket = 0
        // Bande de papier étroite et haute : la forme d'un ticket de caisse.
        if let premiere = pages.first, premiere.largeur > 0, Double(premiere.hauteur) / Double(premiere.largeur) >= 2 { ticket += 3 }
        if a(#"\bticket\b"#) { ticket += 2 }
        if a(#"\b(cb|carte bancaire|sans contact|visa|mastercard|paiement carte)\b"#) { ticket += 2 }
        if a(#"\b(rendu|monnaie rendue|especes)\b"#) { ticket += 2 }
        if a(#"\b(caisse|caissier|caissiere|merci de votre visite|a bientot|merci et a bientot)\b"#) { ticket += 2 }
        if a(#"\btotal\b"#) { ticket += 1 }
        if a(#"\b([01]?\d|2[0-3]):[0-5]\d\b"#) { ticket += 1 }
        if lignes.filter({ $0.range(of: #"\d+[.,]\d{2} ?(€|eur)?$"#, options: .regularExpression) != nil }).count >= 5 { ticket += 1 }
        return (ticket, facture)
    }

    /// Minuscules, sans accents : « Échéance » et « ECHEANCE » se lisent pareil.
    static func normaliser(_ texte: String) -> String {
        texte.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
    }
}

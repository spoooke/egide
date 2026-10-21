import Foundation

/// Réglages du budget repris du « Suivi hebdo ». Remplacés par des modèles modifiables en phase 1 de Money.
enum Budget {
    static let plafondHebdo: Decimal = 135

    /// Montant en euros, à la française (« 135 € », « 12,50 € »).
    static func euros(_ montant: Decimal) -> String {
        let entier = montant == montant.rounded(0)
        return montant.formatted(.currency(code: "EUR")
            .locale(Locale(identifier: "fr_FR"))
            .precision(.fractionLength(entier ? 0 : 2)))
    }
}

extension Decimal {
    func rounded(_ decimales: Int) -> Decimal {
        var source = self, resultat = Decimal()
        NSDecimalRound(&resultat, &source, decimales, .plain)
        return resultat
    }
}

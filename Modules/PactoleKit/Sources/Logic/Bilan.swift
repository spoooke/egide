import Foundation

/// Bilan d'un mois : revenus, frais fixes, budget variable (revenus − frais fixes), dépenses et reste,
/// et comparaison de chaque poste avec le mois précédent.
struct BilanMois: Equatable {
    var revenus: Int
    var fraisFixes: Int
    var depenses: Int
    var parPoste: [String: Int]
    var parPosteMoisPrecedent: [String: Int]

    var budgetVariable: Int { revenus - fraisFixes }
    var reste: Int { budgetVariable - depenses }

    /// Écart avec le mois précédent pour un poste (positif : plus dépensé).
    func ecart(_ posteID: String) -> Int { (parPoste[posteID] ?? 0) - (parPosteMoisPrecedent[posteID] ?? 0) }

    static func calculer(mois date: Date, depenses: [Depense], frais: [FraisFixe], revenus: [Revenu],
                         calendrier: Calendar = .francais) -> BilanMois {
        let mois = Periodes.mois(contenant: date, calendrier: calendrier)
        let precedent = Periodes.mois(contenant: calendrier.date(byAdding: .month, value: -1, to: mois.start)!, calendrier: calendrier)
        let cle = Revenu.cle(mois.start, calendrier: calendrier)
        let parPoste = Cumuls.parPoste(depenses, mois: mois)
        return BilanMois(
            revenus: revenus.filter { $0.mois == cle }.reduce(0) { $0 + $1.montantCentimes },
            // Les frais annuels sont déjà dans les dépenses du jour où ils sont payés.
            fraisFixes: frais.filter { $0.actif && !$0.annuel }.reduce(0) { $0 + $1.montantCentimes },
            depenses: parPoste.values.reduce(0, +),
            parPoste: parPoste,
            parPosteMoisPrecedent: Cumuls.parPoste(depenses, mois: precedent))
    }
}

/// Seuils d'alerte des postes (80 % du plafond du mois).
enum AlertePlafond {
    static let seuil = 0.8

    /// Vrai si l'ajout de `ajout` centimes fait passer le poste au-dessus de 80 % de son plafond ce mois-ci.
    static func franchit(totalAvant: Int, ajout: Int, plafond: Int?) -> Bool {
        guard let plafond, plafond > 0 else { return false }
        let limite = Double(plafond) * seuil
        return Double(totalAvant) < limite && Double(totalAvant + ajout) >= limite
    }
}

enum Dimanche {
    /// Prochain dimanche à 20 h (aujourd'hui si on est dimanche avant 20 h).
    static func prochain(apres date: Date, heure: Int = 20, calendrier: Calendar = .francais) -> Date {
        var cible = DateComponents()
        cible.weekday = 1 // dimanche
        cible.hour = heure
        cible.minute = 0
        return calendrier.nextDate(after: date, matching: cible, matchingPolicy: .nextTime)!
    }
}

/// Dépenses de plusieurs mois de suite, par poste (graphiques des six derniers mois).
struct Historique: Equatable {
    struct Mois: Equatable {
        /// Premier jour du mois, à 0 h.
        var debut: Date
        var parPoste: [String: Int]
        var total: Int { parPoste.values.reduce(0, +) }
    }

    /// Du plus ancien au plus récent ; le dernier est le mois de `fin` (en cours, donc incomplet, si c'est maintenant).
    var mois: [Mois]

    init(depenses: [Depense], nombre: Int = 6, fin: Date = .now, calendrier: Calendar = .francais) {
        let dernier = Periodes.mois(contenant: fin, calendrier: calendrier).start
        mois = (0..<nombre).reversed().map { recul in
            let periode = Periodes.mois(contenant: calendrier.date(byAdding: .month, value: -recul, to: dernier)!, calendrier: calendrier)
            return Mois(debut: periode.start, parPoste: Cumuls.parPoste(depenses, mois: periode))
        }
    }

    /// Montants d'un poste, mois par mois.
    func serie(_ posteID: String) -> [Int] { mois.map { $0.parPoste[posteID] ?? 0 } }

    /// Moyenne d'un poste sur les mois complets (sans le mois en cours), arrondie au centime ; nil s'il n'y en a pas.
    func moyenne(_ posteID: String, maintenant: Date = .now, calendrier: Calendar = .francais) -> Int? {
        let complets = mois.filter { Periodes.mois(contenant: $0.debut, calendrier: calendrier).end <= maintenant }
        guard !complets.isEmpty else { return nil }
        let somme = complets.reduce(0) { $0 + ($1.parPoste[posteID] ?? 0) }
        return Int((Double(somme) / Double(complets.count)).rounded())
    }
}

import Foundation

/// Reste à dépenser de la semaine en cours (du lundi au dimanche).
struct Semaine: Equatable {
    enum Etat: Equatable {
        /// Plus de 25 % du plafond restant.
        case large
        /// Moins de 25 % du plafond restant.
        case serre
        /// Plafond dépassé.
        case depasse
    }

    let plafond: Decimal
    let depense: Decimal
    /// Jours restants jusqu'à dimanche, aujourd'hui compris (lundi : 7, dimanche : 1).
    let joursRestants: Int

    init(plafond: Decimal, depense: Decimal, aujourdhui: Date, calendrier: Calendar = .francais) {
        self.plafond = plafond
        self.depense = depense
        // weekday : 1 = dimanche … 7 = samedi.
        let jour = calendrier.component(.weekday, from: aujourdhui)
        joursRestants = jour == 1 ? 1 : 9 - jour
    }

    var reste: Decimal { plafond - depense }

    /// Part du plafond encore disponible, entre 0 et 1 (pour la jauge).
    var proportionRestante: Double {
        guard plafond > 0, reste > 0 else { return 0 }
        return min(1, NSDecimalNumber(decimal: reste / plafond).doubleValue)
    }

    /// Montant disponible par jour jusqu'à dimanche, arrondi au centime inférieur.
    var parJour: Decimal {
        guard reste > 0 else { return 0 }
        var brut = reste / Decimal(joursRestants), arrondi = Decimal()
        NSDecimalRound(&arrondi, &brut, 2, .down)
        return arrondi
    }

    var etat: Etat {
        if reste < 0 { return .depasse }
        return reste * 4 < plafond ? .serre : .large
    }
}

extension Calendar {
    /// Calendrier grégorien français : semaine du lundi au dimanche.
    static var francais: Calendar {
        var calendrier = Calendar(identifier: .gregorian)
        calendrier.locale = Locale(identifier: "fr_FR")
        calendrier.firstWeekday = 2
        return calendrier
    }
}

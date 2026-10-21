import Foundation

/// Semaines (lundi → dimanche) et mois, au calendrier français.
enum Periodes {
    static func semaine(contenant date: Date, calendrier: Calendar = .francais) -> DateInterval {
        calendrier.dateInterval(of: .weekOfYear, for: date)!
    }

    static func mois(contenant date: Date, calendrier: Calendar = .francais) -> DateInterval {
        calendrier.dateInterval(of: .month, for: date)!
    }

    /// « 29 sept. – 5 oct. »
    static func libelleSemaine(_ semaine: DateInterval, calendrier: Calendar = .francais) -> String {
        let fin = calendrier.date(byAdding: .day, value: -1, to: semaine.end)!
        let format = Date.FormatStyle(locale: Locale(identifier: "fr_FR")).day().month(.abbreviated)
        return "\(semaine.start.formatted(format)) – \(fin.formatted(format))"
    }
}

extension DateInterval {
    /// Intervalle semi-ouvert [début, fin[ : lundi 0 h appartient à la nouvelle semaine seulement
    /// (DateInterval.contains inclut la fin).
    func inclut(_ date: Date) -> Bool { date >= start && date < end }
}

/// Calculs sur une liste de dépenses.
enum Cumuls {
    /// Total de la semaine compté dans le plafond hebdo (sans les postes hors plafond, comme Imprévu).
    static func totalSemaine(_ depenses: [Depense], postesHorsPlafond: Set<String>, semaine: DateInterval) -> Int {
        depenses.filter { semaine.inclut($0.date) && !postesHorsPlafond.contains($0.posteID) && $0.rembourseLe == nil }
            .reduce(0) { $0 + $1.montantCentimes }
    }

    /// Total par poste sur le mois (clé : identifiant du poste), sans les frais pro remboursés.
    static func parPoste(_ depenses: [Depense], mois: DateInterval) -> [String: Int] {
        depenses.filter { mois.inclut($0.date) && $0.rembourseLe == nil }
            .reduce(into: [:]) { $0[$1.posteID, default: 0] += $1.montantCentimes }
    }

    /// Dépenses groupées par semaine, de la plus récente à la plus ancienne.
    static func parSemaine(_ depenses: [Depense], calendrier: Calendar = .francais) -> [(semaine: DateInterval, depenses: [Depense])] {
        Dictionary(grouping: depenses) { Periodes.semaine(contenant: $0.date, calendrier: calendrier).start }
            .map { (Periodes.semaine(contenant: $0.key, calendrier: calendrier), $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.semaine.start > $1.semaine.start }
    }
}

/// État d'un poste par rapport à son plafond du mois.
enum EtatPlafond: Equatable {
    case sansPlafond
    case large      // moins de 80 %
    case proche     // de 80 % à 100 %
    case depasse    // au-delà

    init(totalCentimes: Int, plafondCentimes: Int?) {
        guard let plafond = plafondCentimes, plafond > 0 else { self = .sansPlafond; return }
        if totalCentimes > plafond { self = .depasse }
        else if totalCentimes * 5 >= plafond * 4 { self = .proche }
        else { self = .large }
    }
}

/// Saisie d'un montant à la française (« 12,50 », « 12.5 », « 12 € ») en centimes.
enum Montant {
    static func centimes(depuis texte: String) -> Int? {
        let nettoye = texte.replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: "\u{202F}", with: "").replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: ".")
        guard !nettoye.isEmpty, nettoye.filter({ $0 == "." }).count <= 1,
              nettoye.allSatisfy({ $0.isNumber || $0 == "." }),
              let valeur = Decimal(string: nettoye, locale: Locale(identifier: "en_US")), valeur > 0 else { return nil }
        if let point = nettoye.firstIndex(of: "."), nettoye.distance(from: point, to: nettoye.endIndex) > 3 { return nil }
        return NSDecimalNumber(decimal: valeur * 100).intValue
    }

    static func texte(_ centimes: Int) -> String { Budget.euros(Decimal(centimes) / 100) }
}

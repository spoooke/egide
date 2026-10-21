import Foundation

/// Solde du compte saisi à la main, projeté jusqu'à la prochaine paie.
/// Tout ce qui est saisi après le point (Apple Pay « en cours » compris) est considéré comme débité ;
/// les frais fixes mensuels sont prélevés à leur jour. La paie n'a pas de date fixe : elle est attendue au plus tard
/// le jour `jourPaie` (pire cas), ou comptée dès qu'elle est marquée reçue.
struct Tresorerie: Equatable {
    /// Solde aujourd'hui (centimes, négatif : découvert).
    var soldeAujourdhui: Int
    var prochainePaie: Date
    var paieSuivante: Date
    /// Solde la veille de la prochaine paie si plus rien n'est dépensé (frais fixes d'ici là déduits).
    var soldeAvantPaie: Int
    /// Ce qui peut encore être dépensé d'ici la prochaine paie en gardant la marge (négatif : déjà trop bas).
    var aDepenserAvantPaie: Int
    /// De la prochaine paie à la suivante : solde avant paie + salaire − frais fixes du cycle − marge.
    var aDepenserCycleSuivant: Int
    /// Jours restants avant la prochaine paie (au moins 1) et durée du cycle suivant.
    var joursAvantPaie: Int
    var joursCycleSuivant: Int

    /// `paieRecue` : moment où le salaire a été marqué reçu (avant la date au plus tard du mois).
    static func calculer(solde: Int, datePoint: Date, jourPaie: Int, salaire: Int, marge: Int, paieRecue: Date? = nil,
                         depenses: [Depense], frais: [FraisFixe], virements: [Virement] = [], maintenant: Date = .now,
                         calendrier: Calendar = .francais) -> Tresorerie {
        let mensuels = frais.filter { $0.actif && !$0.annuel }
        func prelevements(_ debut: Date, _ fin: Date) -> Int {
            mensuels.reduce(0) { $0 + $1.montantCentimes * echeances(jour: $1.jour, apres: debut, jusqua: fin, calendrier: calendrier) }
        }
        let depense = depenses.filter { $0.date > datePoint && $0.date <= maintenant }.reduce(0) { $0 + $1.montantCentimes }
        var paies = echeances(jour: jourPaie, apres: datePoint, jusqua: maintenant, calendrier: calendrier)
        var depuis = maintenant
        // Salaire reçu avant sa date au plus tard : compté maintenant, et cette échéance-là est sautée.
        if let paieRecue, paieRecue > datePoint, paieRecue <= maintenant {
            let attendue = echeance(jour: jourPaie, mois: paieRecue, calendrier: calendrier)
            if attendue > maintenant {
                paies += 1
                depuis = attendue
            }
        }
        let recu = virements.filter { $0.date > datePoint && $0.date <= maintenant }.reduce(0) { $0 + $1.montantCentimes }
        // Frais pro remboursé depuis le solde saisi : l'argent est revenu sur le compte.
        let rembourse = depenses.filter { $0.rembourseLe.map { $0 > datePoint && $0 <= maintenant } ?? false }
            .reduce(0) { $0 + $1.montantCentimes }
        let soldeAujourdhui = solde + recu + rembourse - depense - prelevements(datePoint, maintenant) + paies * salaire

        let prochaine = prochaineEcheance(jour: jourPaie, apres: depuis, calendrier: calendrier)
        let suivante = prochaineEcheance(jour: jourPaie, apres: prochaine, calendrier: calendrier)
        // Un frais prélevé le jour de la paie est compté avant elle (au pire, le calcul est prudent).
        let avantPaie = soldeAujourdhui - prelevements(maintenant, prochaine)
        let cycle = avantPaie + salaire - prelevements(prochaine, calendrier.date(byAdding: .day, value: -1, to: suivante)!)
        let jours = { (a: Date, b: Date) in
            max(calendrier.dateComponents([.day], from: calendrier.startOfDay(for: a), to: calendrier.startOfDay(for: b)).day ?? 1, 1)
        }
        return Tresorerie(soldeAujourdhui: soldeAujourdhui, prochainePaie: prochaine, paieSuivante: suivante,
                          soldeAvantPaie: avantPaie, aDepenserAvantPaie: avantPaie - marge,
                          aDepenserCycleSuivant: cycle - marge,
                          joursAvantPaie: jours(maintenant, prochaine), joursCycleSuivant: jours(prochaine, suivante))
    }

    /// Montant par semaine sur un nombre de jours, arrondi à l'euro inférieur.
    static func parSemaine(_ centimes: Int, jours: Int) -> Int {
        guard centimes > 0 else { return 0 }
        return centimes * 7 / max(jours, 1) / 100 * 100
    }

    /// Montant par jour, arrondi à l'euro inférieur.
    static func parJour(_ centimes: Int, jours: Int) -> Int {
        guard centimes > 0 else { return 0 }
        return centimes / max(jours, 1) / 100 * 100
    }

    /// Date (à 0 h) du jour `jour` dans le mois de `date`, ramené au dernier jour pour un mois trop court.
    static func echeance(jour: Int, mois date: Date, calendrier: Calendar = .francais) -> Date {
        let mois = Periodes.mois(contenant: date, calendrier: calendrier)
        let nombre = calendrier.range(of: .day, in: .month, for: mois.start)?.count ?? 28
        return calendrier.date(byAdding: .day, value: min(max(jour, 1), nombre) - 1, to: mois.start)!
    }

    /// Nombre d'échéances mensuelles (jour `jour` à 0 h) dans ]debut, fin].
    static func echeances(jour: Int, apres debut: Date, jusqua fin: Date, calendrier: Calendar = .francais) -> Int {
        guard fin > debut else { return 0 }
        var compte = 0
        var mois = Periodes.mois(contenant: debut, calendrier: calendrier).start
        while mois <= fin {
            let date = echeance(jour: jour, mois: mois, calendrier: calendrier)
            if date > debut && date <= fin { compte += 1 }
            mois = calendrier.date(byAdding: .month, value: 1, to: mois)!
        }
        return compte
    }

    /// Première échéance (à 0 h) strictement après `date` : la paie d'aujourd'hui est déjà passée.
    static func prochaineEcheance(jour: Int, apres date: Date, calendrier: Calendar = .francais) -> Date {
        let ceMois = echeance(jour: jour, mois: date, calendrier: calendrier)
        if ceMois > date { return ceMois }
        return echeance(jour: jour, mois: calendrier.date(byAdding: .month, value: 1, to: ceMois)!, calendrier: calendrier)
    }
}

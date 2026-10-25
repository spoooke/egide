import Foundation
import SwiftData
import UserNotifications

/// Notifications de Money (activées dans Réglages, propres à chaque appareil) :
/// bilan de la semaine le dimanche à 20 h, alerte quand un poste atteint 80 % de son plafond du mois.
@MainActor
enum PactoleNotifications {
    static let cleBilan = "money.notifications.bilan"
    static let cleAlertes = "money.notifications.alertes"
    private static let idBilan = "money.bilan.dimanche"
    private static let clePlanifie = "money.notifications.bilanPlanifie"

    static var bilanActif: Bool { PactoleReglages.defaults.bool(forKey: cleBilan) }
    static var alertesActives: Bool { PactoleReglages.defaults.bool(forKey: cleAlertes) }

    static func demanderAutorisation() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// (Re)programme le bilan du prochain dimanche avec les chiffres de la semaine en cours.
    /// Appelé après chaque enregistrement : le texte est toujours celui de la dernière dépense connue.
    static func planifierBilan(_ context: ModelContext, maintenant: Date = .now) {
        // Le centre de notifications n'est touché que s'il y a quelque chose à faire
        // (hors d'une vraie app, dans les tests, y accéder fait planter le processus).
        let dejaPlanifie = PactoleReglages.defaults.bool(forKey: clePlanifie)
        guard bilanActif else {
            if dejaPlanifie {
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [idBilan])
                PactoleReglages.defaults.set(false, forKey: clePlanifie)
            }
            return
        }
        let centre = UNUserNotificationCenter.current()
        PactoleReglages.defaults.set(true, forKey: clePlanifie)
        let quand = Dimanche.prochain(apres: maintenant)
        let semaine = Periodes.semaine(contenant: quand)
        let depenses = (try? context.fetch(FetchDescriptor<Depense>())) ?? []
        let postes = (try? context.fetch(FetchDescriptor<Poste>())) ?? []
        let horsPlafond = Set(postes.filter(\.horsPlafondHebdo).map(\.syncID))
        let total = Cumuls.totalSemaine(depenses, postesHorsPlafond: horsPlafond, semaine: semaine)
        let plafond = PactoleReglages.plafondHebdoCentimes
        let contenu = UNMutableNotificationContent()
        contenu.title = "Bilan de la semaine"
        contenu.body = total <= plafond
            ? "\(Montant.texte(total)) dépensés sur \(Montant.texte(plafond)) : \(Montant.texte(plafond - total)) d'économisés."
            : "\(Montant.texte(total)) dépensés : plafond de \(Montant.texte(plafond)) dépassé de \(Montant.texte(total - plafond))."
        contenu.sound = .default
        let composants = Calendar.francais.dateComponents([.year, .month, .day, .hour, .minute], from: quand)
        centre.add(UNNotificationRequest(identifier: idBilan, content: contenu,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: composants, repeats: false)))
    }

    /// Alerte immédiate si cette dépense fait passer son poste à 80 % du plafond du mois.
    static func verifierPlafond(apres depense: Depense, dans context: ModelContext) {
        guard alertesActives,
              let poste = (try? context.fetch(FetchDescriptor<Poste>()))?.first(where: { $0.syncID == depense.posteID }),
              let plafond = poste.plafondMensuelCentimes else { return }
        let mois = Periodes.mois(contenant: depense.date)
        let autres = ((try? context.fetch(FetchDescriptor<Depense>())) ?? [])
            .filter { $0.posteID == poste.syncID && mois.inclut($0.date) && $0.syncID != depense.syncID }
            .reduce(0) { $0 + $1.montantCentimes }
        guard AlertePlafond.franchit(totalAvant: autres, ajout: depense.montantCentimes, plafond: plafond) else { return }
        let contenu = UNMutableNotificationContent()
        contenu.title = "\(poste.nom) : 80 % du plafond"
        contenu.body = "\(Montant.texte(autres + depense.montantCentimes)) dépensés ce mois-ci sur \(Montant.texte(plafond))."
        contenu.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "money.alerte.\(poste.syncID).\(Revenu.cle(depense.date))",
                                                                     content: contenu, trigger: nil))
    }
}

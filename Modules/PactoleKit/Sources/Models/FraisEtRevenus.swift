import Foundation
import SwiftData

/// Frais fixe (abonnement, crédit, assurance, téléphone…) : prélevé chaque mois, jamais dans le budget de la semaine.
/// Un frais annuel n'est qu'un rappel : son paiement est saisi comme une dépense le jour où il tombe.
@Model
final class FraisFixe {
    var syncID: String = UUID().uuidString
    var nom: String = ""
    var montantCentimes: Int = 0
    /// Jour du prélèvement dans le mois (1 à 31).
    var jour: Int = 1
    var categorieRaw: String = CategorieFrais.abonnement.rawValue
    /// Mois du prélèvement (1 à 12) d'un frais annuel ; nil : prélevé chaque mois.
    var moisAnnuel: Int?
    /// Arrêté (abonnement résilié) : gardé pour l'historique, plus compté.
    var actif: Bool = true
    /// Libellé bancaire normalisé de ce frais (« itunesappst appl », « sogefinanc expresso franfinanc »), appris quand
    /// une opération du relevé lui est rattachée ; vide : son nom sert à le retrouver.
    var motifBanque: String = ""
    var modifiedAt: Date = Date.now

    init(nom: String, montantCentimes: Int, jour: Int, categorie: CategorieFrais) {
        self.nom = nom
        self.montantCentimes = montantCentimes
        self.jour = min(max(jour, 1), 31)
        self.categorieRaw = categorie.rawValue
    }

    var annuel: Bool { moisAnnuel != nil }

    /// « le 7 du mois » ou « le 7 octobre, chaque année ».
    var echeance: String {
        guard let moisAnnuel else { return "le \(jour) du mois" }
        let nomMois = Calendar.francais.standaloneMonthSymbols[moisAnnuel - 1]
        return "le \(jour) \(nomMois), chaque année"
    }

    var categorie: CategorieFrais {
        get { CategorieFrais(rawValue: categorieRaw) ?? .autre }
        set { categorieRaw = newValue.rawValue }
    }
}

enum CategorieFrais: String, CaseIterable, Identifiable, Sendable {
    case logement, credit, assurance, telephone, abonnement, sport, autre

    var id: String { rawValue }

    var libelle: String {
        switch self {
        case .logement: "Logement"
        case .credit: "Crédits"
        case .assurance: "Assurances"
        case .telephone: "Téléphone et internet"
        case .abonnement: "Abonnements"
        case .sport: "Sport et loisirs"
        case .autre: "Autres"
        }
    }

    var symbole: String {
        switch self {
        case .logement: "house"
        case .credit: "creditcard"
        case .assurance: "shield"
        case .telephone: "antenna.radiowaves.left.and.right"
        case .abonnement: "play.rectangle"
        case .sport: "figure.run"
        case .autre: "tag"
        }
    }
}

/// Revenu d'un mois (salaire, prime…), mois au format « AAAA-MM ».
@Model
final class Revenu {
    var syncID: String = UUID().uuidString
    var mois: String = ""
    var libelle: String = ""
    var montantCentimes: Int = 0
    var modifiedAt: Date = Date.now

    init(mois: String, libelle: String, montantCentimes: Int) {
        self.mois = mois
        self.libelle = libelle
        self.montantCentimes = montantCentimes
    }

    /// « 2026-10 » pour une date d'octobre 2026.
    static func cle(_ date: Date, calendrier: Calendar = .francais) -> String {
        let c = calendrier.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}

/// Virement reçu sur le compte (souvent à soi-même, pour s'aider) : pas un revenu, mais de l'argent en plus sur le compte.
@Model
final class Virement {
    var syncID: String = UUID().uuidString
    var date: Date = Date.now
    var montantCentimes: Int = 0
    var note: String = ""
    var modifiedAt: Date = Date.now

    init(date: Date = .now, montantCentimes: Int, note: String = "") {
        self.date = date
        self.montantCentimes = montantCentimes
        self.note = note
    }
}

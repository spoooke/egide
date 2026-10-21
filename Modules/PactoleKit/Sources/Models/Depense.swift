import Foundation
import SwiftData

/// Origine d'une dépense.
enum SourceDepense: String, Codable, CaseIterable, Sendable {
    case manuel
    case applePay
    case banque
    /// Reçu partagé (capture, PDF, mail) puis vérifié dans la saisie.
    case recu
    /// Payé en espèces (saisie à la main : les retraits du relevé ne sont pas comptés).
    case especes

    var libelle: String {
        switch self {
        case .manuel: "Saisie"
        case .applePay: "Apple Pay"
        case .banque: "Banque"
        case .recu: "Reçu"
        case .especes: "Espèces"
        }
    }
}

/// Une dépense. Montant en centimes (pas d'arrondi), poste désigné par son identifiant de synchro.
@Model
final class Depense {
    /// Identifiant stable entre appareils (synchro par fichiers, phase 4).
    var syncID: String = UUID().uuidString
    var date: Date = Date.now
    var montantCentimes: Int = 0
    var posteID: String = Poste.divers
    var note: String = ""
    var sourceRaw: String = SourceDepense.manuel.rawValue
    /// Commerçant d'un paiement Apple Pay ou bancaire (vide pour une saisie).
    var commercant: String = ""
    /// Carte utilisée (Apple Pay).
    var carte: String = ""
    /// Classement automatique incertain ou nouveau commerçant : à confirmer dans la file « À vérifier ».
    var aVerifier: Bool = false
    /// Empreinte de l'opération du relevé bancaire rapprochée de cette dépense (vide : pas encore rapprochée).
    var banqueID: String = ""
    /// Frais pro remboursé : date du remboursement (nil : pas remboursé). Ne compte plus dans les totaux.
    var rembourseLe: Date?
    var createdAt: Date = Date.now
    var modifiedAt: Date = Date.now

    init(montantCentimes: Int, posteID: String, date: Date = .now, note: String = "", source: SourceDepense = .manuel) {
        self.montantCentimes = montantCentimes
        self.posteID = posteID
        self.date = date
        self.note = note
        self.sourceRaw = source.rawValue
    }

    var montant: Decimal { Decimal(montantCentimes) / 100 }

    var source: SourceDepense {
        get { SourceDepense(rawValue: sourceRaw) ?? .manuel }
        set { sourceRaw = newValue.rawValue }
    }
}

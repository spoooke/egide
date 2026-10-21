import Foundation
import SwiftData

/// Trace d'une dépense ou d'une règle supprimée, pour transmettre la suppression aux autres appareils (30 jours).
@Model
final class MoneyTombstone {
    var syncID: String = ""
    var deletedAt: Date = Date.now

    init(syncID: String, deletedAt: Date = .now) {
        self.syncID = syncID
        self.deletedAt = deletedAt
    }

    static let duree: TimeInterval = 30 * 24 * 3600
}

/// Suppressions faites dans l'app : toujours par ici, pour laisser une trace à la synchro.
@MainActor
enum Suppressions {
    static func supprimer(_ depense: Depense, dans context: ModelContext) {
        context.insert(MoneyTombstone(syncID: depense.syncID))
        context.delete(depense)
    }

    static func supprimer(_ regle: Regle, dans context: ModelContext) {
        context.insert(MoneyTombstone(syncID: regle.syncID))
        context.delete(regle)
    }

    static func supprimer(_ frais: FraisFixe, dans context: ModelContext) {
        context.insert(MoneyTombstone(syncID: frais.syncID))
        context.delete(frais)
    }

    static func supprimer(_ revenu: Revenu, dans context: ModelContext) {
        context.insert(MoneyTombstone(syncID: revenu.syncID))
        context.delete(revenu)
    }

    static func supprimer(_ virement: Virement, dans context: ModelContext) {
        context.insert(MoneyTombstone(syncID: virement.syncID))
        context.delete(virement)
    }
}

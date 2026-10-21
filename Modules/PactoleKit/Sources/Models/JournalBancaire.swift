import Foundation
import SwiftData

/// Opération d'un relevé déjà traitée (liée, créée, ignorée, revenu) : réimporter un relevé est sans effet,
/// et une dépense supprimée après l'import ne revient pas. Propre à l'appareil qui importe (le Mac), pas synchronisé.
@Model
final class OperationVue {
    /// Empreinte de l'opération (`OperationReleve.id`) : rien de lisible du libellé.
    var banqueID: String = ""
    var vueLe: Date = Date.now
    /// Relevé d'où vient l'opération (« 2026-09-04|2026-10-03 »), pour pouvoir annuler son import.
    var releve: String = ""
    /// Dépense créée par l'import, ou revenu ajouté (syncID), supprimés si l'import est annulé.
    var creeID: String = ""
    /// Dépense existante liée par l'import (syncID) : déliée si l'import est annulé.
    var lieeID: String = ""

    init(banqueID: String, releve: String = "") {
        self.banqueID = banqueID
        self.releve = releve
    }
}

/// Relevé déjà ajouté, par sa période « du … au … ».
@Model
final class ReleveAjoute {
    var debut: Date = Date.now
    var fin: Date = Date.now
    var ajouteLe: Date = Date.now
    var operations: Int = 0

    /// « 2026-09-04|2026-10-03 ».
    var cle: String { Releve.jourISO(debut) + "|" + Releve.jourISO(fin) }

    init(debut: Date, fin: Date, operations: Int) {
        self.debut = debut
        self.fin = fin
        self.operations = operations
    }
}

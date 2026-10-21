import EgideUI
import SwiftData
import SwiftUI

/// Dépenses d'un poste sur un mois (ouvert en touchant un poste dans « Par poste » ou le bilan du mois).
struct DepensesPosteView: View {
    let poste: Poste
    let mois: DateInterval

    @Environment(\.modelContext) private var context
    @Query(sort: \Depense.date, order: .reverse) private var depenses: [Depense]
    @Query(sort: \Poste.ordre) private var postes: [Poste]

    var body: some View {
        let liste = depenses.filter { $0.posteID == poste.syncID && mois.inclut($0.date) }
        let total = liste.filter { $0.rembourseLe == nil }.reduce(0) { $0 + $1.montantCentimes }
        List {
            Group {
                Section {
                    LignePoste(poste: poste, total: total)
                }
                Section {
                    if liste.isEmpty {
                        Text("Aucune dépense ce mois-ci.").foregroundStyle(.secondary)
                    }
                    ForEach(liste) { depense in
                        DepenseRow(depense: depense, poste: poste)
                            .menuDepense(depense, postes: postes, context: context)
                    }
                    .onDelete { offsets in
                        for index in offsets { Suppressions.supprimer(liste[index], dans: context) }
                        try? context.save()
                    }
                } header: {
                    Text("\(liste.count) dépense(s)")
                }
            }
            .egideRow()
        }
        .egideList()
        .egideTitre(poste.nom + " · " + mois.start.formatted(Date.FormatStyle(locale: Locale(identifier: "fr_FR")).month(.wide)))
    }
}

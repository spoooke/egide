import EgideUI
import SwiftData
import SwiftUI

/// Semaines précédentes : total par semaine et détail, suppression par glissement.
struct SemainesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Depense.date, order: .reverse) private var depenses: [Depense]
    @Query(sort: \Poste.ordre) private var postes: [Poste]
    @AppStorage("money.plafondHebdoCentimes") private var plafondHebdo = 135_00

    var body: some View {
        let debut = Periodes.semaine(contenant: .now).start
        let anciennes = Cumuls.parSemaine(depenses.filter { $0.date < debut })
        let postesParID = Dictionary(postes.map { ($0.syncID, $0) }) { a, _ in a }
        let horsPlafond = Set(postes.filter(\.horsPlafondHebdo).map(\.syncID))
        List {
            Group {
                if anciennes.isEmpty {
                    ContentUnavailableView("Aucune semaine précédente", systemImage: "calendar")
                }
                ForEach(anciennes, id: \.semaine.start) { groupe in
                    Section {
                        ForEach(groupe.depenses) { depense in
                            DepenseRow(depense: depense, poste: postesParID[depense.posteID])
                                .menuDepense(depense, postes: postes, context: context)
                        }
                        .onDelete { offsets in
                            for index in offsets { Suppressions.supprimer(groupe.depenses[index], dans: context) }
                            try? context.save()
                        }
                    } header: {
                        let total = Cumuls.totalSemaine(groupe.depenses, postesHorsPlafond: horsPlafond, semaine: groupe.semaine)
                        HStack {
                            Text(Periodes.libelleSemaine(groupe.semaine))
                            Spacer()
                            Text("\(Montant.texte(total)) / \(Montant.texte(plafondHebdo))")
                                .foregroundStyle(total > plafondHebdo ? .red : .secondary)
                        }
                    }
                }
            }
            .egideRow()
        }
        .egideList()
        .egideTitre("Semaines précédentes")
    }
}

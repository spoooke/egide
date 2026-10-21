import EgideUI
import SwiftData
import SwiftUI

/// File « À vérifier » : paiements classés avec un doute (nouveau commerçant, Leclerc hors tabac, aucune règle).
/// Toucher un poste confirme la dépense et retient le commerçant pour les prochains paiements.
struct AVerifierView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Depense> { $0.aVerifier }, sort: \Depense.date, order: .reverse) private var depenses: [Depense]
    @Query(sort: \Poste.ordre) private var postes: [Poste]
    @State private var toutValider = false

    var body: some View {
        let postesParID = Dictionary(postes.map { ($0.syncID, $0) }) { a, _ in a }
        List {
            Group {
                if depenses.isEmpty {
                    ContentUnavailableView("Rien à vérifier", systemImage: "checkmark.circle",
                                           description: Text("Les paiements Apple Pay classés avec un doute arrivent ici."))
                }
                ForEach(depenses) { depense in
                    Menu {
                        if depense.source == .banque {
                            MenuFraisFixe(depense: depense)
                            Divider()
                        }
                        ForEach(postes) { poste in
                            Button {
                                try? Paiements.confirmer(depense, posteID: poste.syncID, dans: context)
                            } label: {
                                Label(poste.nom, systemImage: poste.syncID == depense.posteID ? "checkmark" : poste.symbole)
                            }
                        }
                    } label: {
                        DepenseRow(depense: depense, poste: postesParID[depense.posteID])
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading) {
                        Button("Confirmer", systemImage: "checkmark") {
                            try? Paiements.confirmer(depense, posteID: depense.posteID, dans: context)
                        }
                        .tint(.green)
                    }
                }
                .onDelete { offsets in
                    for index in offsets { Suppressions.supprimer(depenses[index], dans: context) }
                    try? context.save()
                }
            }
            .egideRow()
        }
        .egideList()
        .egideTitre("À vérifier")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Tout valider", systemImage: "checkmark.circle") { toutValider = true }
                    .disabled(depenses.isEmpty)
            }
        }
        .confirmationDialog("Valider les \(depenses.count) dépense(s) dans leur poste actuel ?", isPresented: $toutValider,
                            titleVisibility: .visible) {
            Button("Tout valider") {
                for depense in depenses { try? Paiements.confirmer(depense, posteID: depense.posteID, dans: context) }
            }
        } message: {
            Text("Chaque commerçant est retenu dans son poste pour les prochains paiements. Change d'abord le poste de celles qui sont mal classées.")
        }
    }
}

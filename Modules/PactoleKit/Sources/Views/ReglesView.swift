import EgideUI
import SwiftData
import SwiftUI

/// Règles de classement des paiements Apple Pay : commerçant contenant ce texte → poste.
struct ReglesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Regle.motif) private var regles: [Regle]
    @Query(sort: \Poste.ordre) private var postes: [Poste]
    @State private var nouveauMotif = ""
    @State private var nouveauPoste = "courses"

    /// Imprévu n'est jamais attribué automatiquement.
    private var postesAutorises: [Poste] { postes.filter { $0.syncID != Poste.imprevu } }

    var body: some View {
        Form {
            Group {
                Section {
                    TextField("Nom ou partie du nom du commerçant", text: $nouveauMotif)
                        .sansMajuscules()
                    Picker("Poste", selection: $nouveauPoste) {
                        ForEach(postesAutorises) { Text($0.nom).tag($0.syncID) }
                    }
                    Button("Ajouter la règle", systemImage: "plus") {
                        context.insert(Regle(motif: nouveauMotif, posteID: nouveauPoste))
                        try? context.save()
                        nouveauMotif = ""
                    }
                    .disabled(Classement.normaliser(nouveauMotif).isEmpty)
                } header: {
                    Text("Nouvelle règle")
                }

                Section {
                    ForEach(regles) { regle in
                        @Bindable var regle = regle
                        Picker(regle.motif, selection: $regle.posteID) {
                            ForEach(postesAutorises) { Text($0.nom).tag($0.syncID) }
                        }
                        .onChange(of: regle.posteID) { regle.modifiedAt = .now; try? context.save() }
                    }
                    .onDelete { offsets in
                        for index in offsets { Suppressions.supprimer(regles[index], dans: context) }
                        try? context.save()
                    }
                } header: {
                    Text("Règles (\(regles.count))")
                } footer: {
                    Text("La règle au texte le plus long l'emporte. Leclerc : un multiple exact de 13 € va en Tabac, sinon Courses à vérifier. Sans règle : Divers à vérifier. Un nouveau commerçant est toujours à vérifier, et Imprévu n'est jamais choisi automatiquement. Confirmer une dépense à vérifier crée ou corrige la règle de ce commerçant.")
                }
            }
            .egideRow()
        }
        .egideList()
        .formStyle(.grouped)
        .egideTitre("Classement")
    }
}

import EgideUI
import SwiftData
import SwiftUI

/// Virements reçus (souvent à soi-même), en vert ; ceux d'un mois depuis l'accueil, tous depuis les réglages.
struct VirementsView: View {
    /// Mois affiché ; nil : tous les virements, par mois.
    var mois: DateInterval?

    @Environment(\.modelContext) private var context
    @Query(sort: \Virement.date, order: .reverse) private var virements: [Virement]
    @State private var date = Date.now
    @State private var montant = ""
    @State private var note = ""

    private let format = Date.FormatStyle(locale: Locale(identifier: "fr_FR"))

    var body: some View {
        let affiches = mois.map { m in virements.filter { m.inclut($0.date) } } ?? virements
        let parMois = Dictionary(grouping: affiches) { Revenu.cle($0.date) }
        List {
            Group {
                Section("Nouveau virement reçu") {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Montant", text: $montant).clavierMontant()
                    TextField("Note (facultatif)", text: $note)
                    Button("Ajouter", systemImage: "plus") {
                        guard let centimes = Montant.centimes(depuis: montant) else { return }
                        context.insert(Virement(date: date, montantCentimes: centimes, note: note.trimmingCharacters(in: .whitespaces)))
                        try? context.save()
                        montant = ""
                        note = ""
                    }
                    .disabled(Montant.centimes(depuis: montant) == nil)
                }
                ForEach(parMois.keys.sorted(by: >), id: \.self) { cle in
                    let liste = parMois[cle] ?? []
                    Section {
                        ForEach(liste) { v in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(v.note.isEmpty ? "Virement" : v.note)
                                    Text(v.date.formatted(format.weekday(.wide).day().month(.wide)))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("+ " + Montant.texte(v.montantCentimes)).monospacedDigit().foregroundStyle(.green)
                            }
                            .menuSupprimer { Suppressions.supprimer(v, dans: context); try? context.save() }
                        }
                        .onDelete { offsets in
                            for index in offsets { Suppressions.supprimer(liste[index], dans: context) }
                            try? context.save()
                        }
                    } header: {
                        HStack {
                            Text(liste[0].date.formatted(format.month(.wide).year()).capitalized)
                            Spacer()
                            Text("+ " + Montant.texte(liste.reduce(0) { $0 + $1.montantCentimes })).foregroundStyle(.green)
                        }
                    }
                }
            }
            .egideRow()
        }
        .egideList()
        .egideTitre("Virements reçus")
        .onAppear { if let mois, !mois.inclut(.now) { date = mois.start } }
    }
}

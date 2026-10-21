import EgideUI
import SwiftData
import SwiftUI

/// Revenus par mois (salaire net versé, primes…).
struct RevenusView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Revenu.mois, order: .reverse) private var revenus: [Revenu]
    @State private var mois = Date.now
    @State private var libelle = "Salaire"
    @State private var montant = ""

    var body: some View {
        let parMois = Dictionary(grouping: revenus, by: \.mois)
        List {
            Group {
                Section("Nouveau revenu") {
                    DatePicker("Mois", selection: $mois, displayedComponents: .date)
                    TextField("Libellé", text: $libelle)
                    TextField("Montant net", text: $montant).clavierMontant()
                    Button("Ajouter", systemImage: "plus") {
                        guard let centimes = Montant.centimes(depuis: montant) else { return }
                        context.insert(Revenu(mois: Revenu.cle(mois), libelle: libelle.trimmingCharacters(in: .whitespaces),
                                              montantCentimes: centimes))
                        try? context.save()
                        montant = ""
                    }
                    .disabled(Montant.centimes(depuis: montant) == nil)
                }
                ForEach(parMois.keys.sorted(by: >), id: \.self) { cle in
                    let liste = parMois[cle] ?? []
                    Section {
                        ForEach(liste) { r in
                            LabeledContent(r.libelle, value: Montant.texte(r.montantCentimes))
                                .menuSupprimer { Suppressions.supprimer(r, dans: context); try? context.save() }
                        }
                        .onDelete { offsets in
                            for index in offsets { Suppressions.supprimer(liste[index], dans: context) }
                            try? context.save()
                        }
                    } header: {
                        HStack {
                            Text(Self.titre(cle))
                            Spacer()
                            Text(Montant.texte(liste.reduce(0) { $0 + $1.montantCentimes }))
                        }
                    }
                }
            }
            .egideRow()
        }
        .egideList()
        .egideTitre("Revenus")
    }

    /// « 2026-10 » → « Octobre 2026 ».
    static func titre(_ cle: String) -> String {
        let p = cle.split(separator: "-").compactMap { Int($0) }
        guard p.count == 2, let date = Calendar.francais.date(from: DateComponents(year: p[0], month: p[1], day: 1)) else { return cle }
        return date.formatted(Date.FormatStyle(locale: Locale(identifier: "fr_FR")).month(.wide).year()).capitalized
    }
}

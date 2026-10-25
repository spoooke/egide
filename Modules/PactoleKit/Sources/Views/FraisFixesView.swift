import EgideUI
import SwiftData
import SwiftUI

/// Frais fixes et abonnements : montant et jour de prélèvement, regroupés par catégorie.
struct FraisFixesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \FraisFixe.jour) private var frais: [FraisFixe]
    @State private var edition: FraisFixe?
    @State private var nouveau = false

    var body: some View {
        let actifs = frais.filter(\.actif)
        List {
            Group {
                Section {
                    LabeledContent("Total par mois", value: Montant.texte(actifs.filter { !$0.annuel }.reduce(0) { $0 + $1.montantCentimes }))
                        .font(.headline)
                    let annuels = actifs.filter(\.annuel).reduce(0) { $0 + $1.montantCentimes }
                    if annuels > 0 { LabeledContent("Par an, en plus", value: Montant.texte(annuels)) }
                } footer: {
                    Text("Jamais compté dans le budget de la semaine. Le budget variable du mois = revenus − frais fixes. "
                         + "Un frais annuel est un rappel : son paiement s'ajoute comme une dépense, le jour où il tombe.")
                }
                ForEach(CategorieFrais.allCases) { categorie in
                    let liste = frais.filter { $0.categorie == categorie }
                    if !liste.isEmpty {
                        Section(categorie.libelle) {
                            ForEach(liste) { f in
                                Button { edition = f } label: { ligne(f) }
                                    .buttonStyle(.plain)
                                    .menuSupprimer { Suppressions.supprimer(f, dans: context); try? context.save() }
                            }
                            .onDelete { offsets in
                                for index in offsets { Suppressions.supprimer(liste[index], dans: context) }
                                try? context.save()
                            }
                        }
                    }
                }
            }
            .egideRow()
        }
        .egideList()
        .egideTitre("Frais fixes") {
            Button("Ajouter", systemImage: "plus") { nouveau = true }
        }
        .sheet(item: $edition) { FraisFixeForm(frais: $0) }
        .sheet(isPresented: $nouveau) { FraisFixeForm(frais: nil) }
    }

    private func ligne(_ f: FraisFixe) -> some View {
        HStack {
            Image(systemName: f.categorie.symbole).foregroundStyle(.tint).frame(width: 28)
            VStack(alignment: .leading) {
                Text(f.nom).strikethrough(!f.actif)
                Text(f.actif ? f.echeance : "arrêté").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Montant.texte(f.montantCentimes)).monospacedDigit().foregroundStyle(f.actif ? .primary : .secondary)
        }
        .contentShape(.rect)
    }
}

/// Ajout ou modification d'un frais fixe.
private struct FraisFixeForm: View {
    let frais: FraisFixe?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var nom = ""
    @State private var montant = ""
    @State private var jour = 1
    @State private var categorie = CategorieFrais.abonnement
    @State private var actif = true
    @State private var annuel = false
    @State private var moisAnnuel = Calendar.francais.component(.month, from: .now)
    @State private var motifs = ""

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    TextField("Nom (Netflix, loyer…)", text: $nom)
                    TextField("Montant", text: $montant).clavierMontant()
                    Stepper("Prélevé le \(jour)", value: $jour, in: 1...31)
                    Toggle("Une fois par an", isOn: $annuel)
                    if annuel {
                        Picker("Mois", selection: $moisAnnuel) {
                            ForEach(1...12, id: \.self) { Text(Calendar.francais.standaloneMonthSymbols[$0 - 1].capitalized).tag($0) }
                        }
                    }
                    Picker("Catégorie", selection: $categorie) {
                        ForEach(CategorieFrais.allCases) { Label($0.libelle, systemImage: $0.symbole).tag($0) }
                    }
                    Toggle("En cours", isOn: $actif)
                    Section {
                        TextField("Libellés du relevé", text: $motifs, axis: .vertical).sansMajuscules()
                    } footer: {
                        Text("Appris avec « C'est un frais fixe » sur une dépense du relevé, séparés par « | ». Vide : le nom du frais suffit.")
                    }
                }
                .egideRow()
            }
            .egideList()
            .formStyle(.grouped)
            .navigationTitle(frais == nil ? "Nouveau frais fixe" : "Frais fixe")
            .titreCompact()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer", action: enregistrer)
                        .disabled(nom.trimmingCharacters(in: .whitespaces).isEmpty || Montant.centimes(depuis: montant) == nil)
                }
            }
            .onAppear {
                guard let frais else { return }
                nom = frais.nom; montant = Montant.texte(frais.montantCentimes); jour = frais.jour
                categorie = frais.categorie; actif = frais.actif
                if let mois = frais.moisAnnuel { annuel = true; moisAnnuel = mois }
                motifs = Rapprochement.motifs(frais).joined(separator: " | ")
            }
        }
    }

    private func enregistrer() {
        guard let centimes = Montant.centimes(depuis: montant) else { return }
        let f = frais ?? FraisFixe(nom: "", montantCentimes: 0, jour: 1, categorie: categorie)
        if frais == nil { context.insert(f) }
        f.nom = nom.trimmingCharacters(in: .whitespaces); f.montantCentimes = centimes; f.jour = jour
        f.categorie = categorie; f.actif = actif; f.moisAnnuel = annuel ? moisAnnuel : nil; f.modifiedAt = .now
        f.motifBanque = motifs.split(separator: "|").map { Classement.normaliser(String($0)) }.filter { !$0.isEmpty }.joined(separator: "|")
        try? context.save()
        dismiss()
    }
}

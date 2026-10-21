import EgideUI
import SwiftData
import SwiftUI

/// Saisie éclair : montant (clavier ouvert), poste, note, date (aujourd'hui par défaut).
/// « Espèces » : payé en liquide (montant et motif), compté comme les autres dépenses.
struct SaisieView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// Fin de la saisie (ajout ou annulation) ; par défaut, ferme la fenêtre.
    var terminer: (() -> Void)? = nil
    /// Saisie pré-remplie depuis un reçu partagé.
    var brouillon: BrouillonRecu? = nil
    @Query(sort: \Poste.ordre) private var postes: [Poste]
    @AppStorage("money.dernierPoste") private var dernierPoste = "courses"

    @State private var montant = ""
    @State private var posteID = ""
    @State private var note = ""
    @State private var date = Date.now
    @State private var commercant = ""
    @State private var carte = ""
    @State private var especes = false
    @Query private var depenses: [Depense]
    @FocusState private var montantActif: Bool

    private var centimes: Int? { Montant.centimes(depuis: montant) }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        // Sans étiquette : sur le Mac, un formulaire l'afficherait à gauche du montant.
                        TextField("Montant", text: $montant, prompt: Text("0,00 €"))
                            .labelsHidden()
                            .clavierMontant()
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .multilineTextAlignment(.center)
                            .focused($montantActif)
                    } footer: {
                        if !montant.isEmpty && centimes == nil {
                            Text("Montant invalide : par exemple 12,50").foregroundStyle(.red)
                        }
                    }

                    if brouillon != nil {
                        Section {
                            TextField("Commerçant", text: $commercant)
                            TextField("Carte", text: $carte)
                        } header: {
                            Text("Lu sur le reçu")
                        } footer: {
                            if let releve = depenseDuReleve {
                                Text("Déjà au relevé bancaire : \(Montant.texte(releve.montantCentimes)) le "
                                     + releve.date.formatted(Date.FormatStyle(locale: Locale(identifier: "fr_FR")).day().month(.wide))
                                     + (releve.commercant.isEmpty ? "" : " (\(releve.commercant))")
                                     + ". Elle sera complétée au lieu d'être ajoutée en double.")
                                    .foregroundStyle(.orange)
                            } else if let doublon {
                                Text("Déjà enregistrée ? \(Montant.texte(doublon.montantCentimes)) le "
                                     + doublon.date.formatted(Date.FormatStyle(locale: Locale(identifier: "fr_FR")).day().month(.wide))
                                     + (doublon.commercant.isEmpty ? "" : " chez \(doublon.commercant)") + ".")
                                    .foregroundStyle(.orange)
                            } else if brouillon?.centimes == nil || brouillon?.date == nil {
                                Text("Montant ou date introuvable sur le reçu : vérifie avant d'ajouter.")
                            }
                        }
                    }

                    Section("Poste") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                            ForEach(postes) { poste in
                                let choisi = poste.syncID == posteID
                                Button { posteID = poste.syncID } label: {
                                    Label(poste.nom, systemImage: poste.symbole)
                                        .font(.subheadline.weight(choisi ? .semibold : .regular))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                        .frame(maxWidth: .infinity, minHeight: 40)
                                        .foregroundStyle(choisi ? Color.white : Color.primary)
                                        .background(choisi ? Color.accentColor : Color.secondary.opacity(0.15), in: .capsule)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(choisi ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Section {
                        if brouillon == nil {
                            Toggle("Payé en espèces", systemImage: "banknote", isOn: $especes)
                        }
                        TextField(especes ? "Motif" : "Note (facultatif)", text: $note)
                        DatePicker("Date", selection: $date, in: ...Date.now.addingTimeInterval(86_400), displayedComponents: .date)
                    }
                }
                .egideRow()
            }
            .egideList()
            .formStyle(.grouped)
        .navigationTitle(brouillon == nil ? "Nouvelle dépense" : "Dépense du reçu")
            .titreCompact()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { fermer() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ajouter", action: enregistrer).disabled(centimes == nil || posteID.isEmpty
                                  || (especes && note.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
            .onAppear {
                if let brouillon {
                    if let c = brouillon.centimes { montant = String(format: "%d,%02d", c / 100, c % 100) }
                    if let d = brouillon.date { date = d }
                    commercant = brouillon.commercant
                    carte = brouillon.carte
                }
                montantActif = brouillon?.centimes == nil
            }
            // Les postes arrivent parfois après l'ouverture de la fenêtre : poste par défaut dès qu'ils sont là.
            .onChange(of: postes.map(\.syncID), initial: true) { _, ids in
                guard posteID.isEmpty, !ids.isEmpty else { return }
                // Reçu : poste du commerçant, sinon d'un mot du reçu (mêmes règles que pour Apple Pay) ; Divers à défaut.
                if let brouillon {
                    let regles = ((try? context.fetch(FetchDescriptor<Regle>())) ?? []).map { ($0.motif, $0.posteID) }
                    for texte in [commercant, brouillon.texte] where !texte.isEmpty {
                        let classement = Classement.classer(commercant: texte, centimes: centimes ?? 0, regles: regles,
                                                            commercantsConnus: [])
                        if !classement.aVerifier, ids.contains(classement.posteID) { posteID = classement.posteID; return }
                    }
                    if ids.contains(Poste.divers) { posteID = Poste.divers; return }
                }
                posteID = ids.contains(dernierPoste) ? dernierPoste : ids[0]
            }
        }
    }

    /// Dépense du même jour, du même montant et du même commerçant (déjà arrivée par Apple Pay, par exemple).
    private var doublon: Depense? {
        guard let centimes else { return nil }
        let jour = Calendar.francais.startOfDay(for: date)
        let nom = Classement.normaliser(commercant)
        return depenses.first { d in
            d.montantCentimes == centimes && Calendar.francais.startOfDay(for: d.date) == jour
                && (nom.isEmpty || Paiements.memeCommercant(nom, Classement.normaliser(d.commercant.isEmpty ? d.note : d.commercant)))
        }
    }

    /// Dépense « Banque » déjà importée du relevé qui correspond au reçu : complétée plutôt qu'ajoutée.
    private var depenseDuReleve: Depense? {
        guard brouillon != nil, doublon == nil, let centimes else { return nil }
        return Rapprochement.depenseDuReleve(centimes: centimes, date: date, parmi: depenses)
    }

    private func enregistrer() {
        guard let centimes else { return }
        if let releve = depenseDuReleve {
            releve.posteID = posteID
            releve.aVerifier = false
            let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty { releve.note = note }
            let commercant = commercant.trimmingCharacters(in: .whitespaces)
            if !commercant.isEmpty { releve.commercant = commercant }
            let carte = carte.trimmingCharacters(in: .whitespaces)
            if !carte.isEmpty { releve.carte = carte }
            releve.modifiedAt = .now
            try? context.save()
            dernierPoste = posteID
            fermer()
            return
        }
        let depense = Depense(montantCentimes: centimes, posteID: posteID, date: date,
                              note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                              source: brouillon != nil ? .recu : (especes ? .especes : .manuel))
        depense.commercant = commercant.trimmingCharacters(in: .whitespaces)
        depense.carte = carte.trimmingCharacters(in: .whitespaces)
        context.insert(depense)
        try? context.save()
        PactoleNotifications.verifierPlafond(apres: depense, dans: context)
        dernierPoste = posteID
        fermer()
    }

    private func fermer() {
        if let terminer { terminer() } else { dismiss() }
    }
}

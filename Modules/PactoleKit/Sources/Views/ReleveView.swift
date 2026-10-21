import EgideUI
import SwiftData
import SwiftUI

/// « Relevé du mois » : ce que l'import va faire (lecture vérifiée par les totaux du relevé), avant de l'appliquer.
/// Les crédits sont proposés comme revenus du mois, le salaire coché d'avance.
struct ReleveView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Poste.ordre) private var postes: [Poste]
    @State var plan: Rapprochement.Plan
    @State private var erreur: String?
    /// Import terminé : bilan à afficher.
    var importe: (Rapprochement.Bilan) -> Void

    private static let jour = Date.FormatStyle(locale: Locale(identifier: "fr_FR")).day().month(.abbreviated)

    var body: some View {
        let releve = plan.releve
        let nouvelles = plan.lignes.filter { if case .nouvelle = $0.issue { true } else { false } }
        let liees = plan.lignes.filter { if case .liee = $0.issue { true } else { false } }
        let doutes = plan.lignes.filter { if case .aVerifier = $0.issue { true } else { false } }
        let ignorees = plan.lignes.filter {
            switch $0.issue { case .retrait, .fraisFixe: true; default: false }
        }
        let dejaVues = plan.nombre { $0 == .dejaVue }
        let postesParID = Dictionary(postes.map { ($0.syncID, $0) }) { a, _ in a }
        NavigationStack {
            Form {
                Group {
                    Section {
                        LabeledContent("Période", value: "du \(releve.debut.formatted(Self.jour)) au "
                                       + releve.fin.formatted(Date.FormatStyle(locale: Locale(identifier: "fr_FR")).day().month(.abbreviated).year()))
                        LabeledContent("Opérations", value: "\(releve.operations.count)")
                        LabeledContent("Débits", value: Montant.texte(releve.totalDebits))
                        LabeledContent("Crédits", value: Montant.texte(releve.totalCredits))
                    } footer: {
                        Text("Lecture vérifiée avec les totaux du relevé. Le PDF n'est pas gardé : seules les opérations rejoignent Pactole."
                             + (dejaVues > 0 ? " \(dejaVues) opération(s) déjà importée(s), ignorée(s)." : ""))
                    }

                    if !nouvelles.isEmpty {
                        Section {
                            ForEach(nouvelles) { ligne in
                                if case let .nouvelle(posteID, aVerifier) = ligne.issue {
                                    LigneOperation(operation: ligne.operation,
                                                   detail: (postesParID[posteID]?.nom ?? posteID) + (aVerifier ? " · à vérifier" : ""))
                                }
                            }
                        } header: {
                            Text("Nouvelles dépenses (\(nouvelles.count))")
                        } footer: {
                            Text("Absentes de Pactole (carte sans Apple Pay, prélèvement…) : ajoutées avec la source Banque.")
                        }
                    }

                    if !doutes.isEmpty {
                        Section {
                            ForEach(doutes) { ligne in
                                if case let .aVerifier(depense, candidates) = ligne.issue {
                                    LigneOperation(operation: ligne.operation,
                                                   detail: "\(candidates) dépenses possibles, liée à celle du \(depense.date.formatted(Self.jour))")
                                }
                            }
                        } header: {
                            Text("À vérifier (\(doutes.count))")
                        } footer: {
                            Text("Plusieurs dépenses du même montant : la plus proche en date est liée et passe dans « À vérifier ».")
                        }
                    }

                    if !liees.isEmpty {
                        Section {
                            DisclosureGroup("\(liees.count) déjà dans Pactole (Apple Pay, reçu, saisie)") {
                                ForEach(liees) { ligne in
                                    if case let .liee(depense) = ligne.issue {
                                        LigneOperation(operation: ligne.operation,
                                                       detail: depense.commercant.isEmpty ? depense.source.libelle : depense.commercant)
                                    }
                                }
                            }
                        } header: {
                            Text("Rapprochées")
                        }
                    }

                    if !plan.revenus.isEmpty {
                        Section {
                            ForEach($plan.revenus) { $proposition in
                                Toggle(isOn: $proposition.retenu) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        TextField("Libellé", text: $proposition.libelle)
                                        Text(sousTitre(proposition)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } header: {
                            Text("Revenus du mois")
                        } footer: {
                            Text("Crédits du relevé, comptés dans le mois de l'opération. Seuls ceux cochés sont ajoutés aux revenus.")
                        }
                    }

                    if !ignorees.isEmpty {
                        Section {
                            ForEach(ignorees) { ligne in
                                switch ligne.issue {
                                case .fraisFixe(let nom): LigneOperation(operation: ligne.operation, detail: "Frais fixe : \(nom)")
                                default: LigneOperation(operation: ligne.operation, detail: "Retrait d'espèces")
                                }
                            }
                        } header: {
                            Text("Ignorées (\(ignorees.count))")
                        } footer: {
                            Text("Frais fixes déjà comptés à part ; retraits d'espèces non comptés (saisis à la main, source Espèces).")
                        }
                    }
                }
                .egideRow()
            }
            .egideList()
            .formStyle(.grouped)
            .navigationTitle("Relevé du mois")
            .titreCompact()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Importer", action: importer) }
            }
            .alert("Import impossible", isPresented: Binding { erreur != nil } set: { if !$0 { erreur = nil } }) {
                Button("OK") {}
            } message: {
                Text(erreur ?? "")
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    private func sousTitre(_ p: Rapprochement.PropositionRevenu) -> String {
        var parties = [Montant.texte(p.operation.centimes), p.operation.dateOperation.formatted(Self.jour),
                       RevenusView.titre(p.mois)]
        if p.salaire { parties.append("salaire reconnu") }
        if p.dejaSaisi { parties.append("déjà saisi ce mois-ci") }
        if !p.operation.commercant.isEmpty, !p.salaire { parties.append(p.operation.commercant) }
        return parties.joined(separator: " · ")
    }

    private func importer() {
        do {
            let bilan = try Rapprochement.appliquer(plan, dans: context)
            dismiss()
            importe(bilan)
        } catch {
            erreur = error.localizedDescription
        }
    }
}

/// Opération du relevé : commerçant ou tiers, ce que l'import en fait, date et montant.
private struct LigneOperation: View {
    let operation: OperationReleve
    let detail: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(operation.commercant.isEmpty ? operation.libelle : operation.commercant).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text((operation.credit ? "+ " : "") + Montant.texte(operation.centimes)).monospacedDigit()
                Text((operation.dateAchat() ?? operation.dateOperation)
                    .formatted(Date.FormatStyle(locale: Locale(identifier: "fr_FR")).day().month(.abbreviated)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// « C'est un frais fixe » sur une dépense importée du relevé : la rattacher à un frais existant (son libellé est retenu
/// pour les relevés suivants) ou en créer un. Mensuel : la dépense disparaît (déjà comptée dans les frais fixes) ;
/// annuel : elle reste, en Imprévu.
struct MenuFraisFixe: View {
    let depense: Depense
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<FraisFixe> { $0.actif }, sort: \FraisFixe.nom) private var frais: [FraisFixe]

    var body: some View {
        Menu("C'est un frais fixe", systemImage: "repeat") {
            ForEach(frais) { f in
                Button(f.nom + " · " + Montant.texte(f.montantCentimes) + (f.annuel ? " par an" : "")) {
                    try? Rapprochement.rattacher(depense, a: f, dans: context)
                }
            }
            Divider()
            Button("Nouveau frais mensuel", systemImage: "plus") {
                try? Rapprochement.nouveauFrais(depuis: depense, annuel: false, dans: context)
            }
            Button("Nouveau frais annuel (garder la dépense)", systemImage: "calendar.badge.plus") {
                try? Rapprochement.nouveauFrais(depuis: depense, annuel: true, dans: context)
            }
        }
    }
}

/// Relevés ajoutés (Réglages) : annuler l'import d'un relevé pour l'ajouter de nouveau.
struct RelevesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ReleveAjoute.debut, order: .reverse) private var releves: [ReleveAjoute]
    @State private var aAnnuler: ReleveAjoute?

    private static let date = Date.FormatStyle(locale: Locale(identifier: "fr_FR")).day().month(.abbreviated).year()

    var body: some View {
        List {
            Group {
                if releves.isEmpty {
                    ContentUnavailableView("Aucun relevé", systemImage: "building.columns",
                                           description: Text("« Ajouter un relevé… » sur le Mac, ou glisser le PDF sur la fenêtre."))
                }
                ForEach(releves) { r in
                    LabeledContent("Du \(r.debut.formatted(Self.date)) au \(r.fin.formatted(Self.date))",
                                   value: "\(r.operations) opérations")
                        .contextMenu {
                            Button("Annuler l'import", systemImage: "arrow.uturn.backward", role: .destructive) { aAnnuler = r }
                        }
                        .swipeActions {
                            Button("Annuler l'import", role: .destructive) { aAnnuler = r }
                        }
                }
            }
            .egideRow()
        }
        .egideList()
        .egideTitre("Relevés ajoutés")
        .confirmationDialog("Annuler l'import de ce relevé ?", isPresented: Binding { aAnnuler != nil } set: { if !$0 { aAnnuler = nil } },
                            titleVisibility: .visible) {
            Button("Annuler l'import", role: .destructive) {
                if let aAnnuler { try? Rapprochement.annuler(aAnnuler, dans: context) }
            }
        } message: {
            Text("Les dépenses et revenus ajoutés par ce relevé sont supprimés, les dépenses rapprochées sont déliées. "
                 + "Le relevé pourra être ajouté de nouveau.")
        }
    }
}

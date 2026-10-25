import EgideUI
import SwiftData
import SwiftUI

/// Cumul par poste sur un mois, barre colorée selon le plafond (vert, orange dès 80 %, rouge au-delà).
struct MoisView: View {
    @Query(sort: \Depense.date, order: .reverse) private var depenses: [Depense]
    @Query(sort: \Poste.ordre) private var postes: [Poste]
    @Query private var frais: [FraisFixe]
    @Query private var revenus: [Revenu]
    @State private var date = Date.now

    var body: some View {
        let mois = Periodes.mois(contenant: date)
        let totaux = Cumuls.parPoste(depenses, mois: mois)
        let total = totaux.values.reduce(0, +)
        let plafonds = postes.compactMap(\.plafondMensuelCentimes).reduce(0, +)
        let bilan = BilanMois.calculer(mois: date, depenses: depenses, frais: frais, revenus: revenus)
        List {
            Group {
                Section {
                    LabeledContent("Revenus", value: Montant.texte(bilan.revenus))
                    LabeledContent("Frais fixes", value: "− " + Montant.texte(bilan.fraisFixes))
                    LabeledContent("Budget variable", value: Montant.texte(bilan.budgetVariable)).bold()
                    LabeledContent("Dépensé", value: "− " + Montant.texte(bilan.depenses))
                    LabeledContent("Reste du mois") {
                        Text(Montant.texte(bilan.reste)).bold().foregroundStyle(bilan.reste < 0 ? .red : .green)
                    }
                } header: {
                    Text("Bilan")
                } footer: {
                    if bilan.revenus == 0 { Text("Ajoute les revenus du mois dans Réglages › Revenus.") }
                }
                Section {
                    ForEach(postes) { poste in
                        NavigationLink { DepensesPosteView(poste: poste, mois: mois) } label: {
                            LignePoste(poste: poste, total: totaux[poste.syncID] ?? 0, ecart: bilan.ecart(poste.syncID))
                        }
                    }
                } footer: {
                    let especes = depenses.filter { $0.source == .especes && mois.inclut($0.date) }.reduce(0) { $0 + $1.montantCentimes }
                    Text("Total du mois : \(Montant.texte(total)) pour \(Montant.texte(plafonds)) de plafonds."
                         + (especes > 0 ? " Dont \(Montant.texte(especes)) en espèces." : ""))
                }
            }
            .egideRow()
        }
        .egideList()
        .egideTitre(date.formatted(Date.FormatStyle(locale: Locale(identifier: "fr_FR")).month(.wide).year()).capitalized) {
            Button("Mois précédent", systemImage: "chevron.left") { changerDeMois(-1) }
                .labelStyle(.iconOnly)
            Button("Mois suivant", systemImage: "chevron.right") { changerDeMois(1) }
                .labelStyle(.iconOnly)
                .disabled(Periodes.mois(contenant: date).inclut(.now))
        }
    }

    private func changerDeMois(_ pas: Int) {
        date = Calendar.francais.date(byAdding: .month, value: pas, to: date) ?? date
    }
}

/// Ligne d'un poste : total du mois sur son plafond, barre verte, orange dès 80 %, rouge au-delà.
struct LignePoste: View {
    let poste: Poste
    let total: Int
    /// Écart avec le mois précédent (positif : plus dépensé).
    var ecart: Int = 0

    var body: some View {
        let etat = EtatPlafond(totalCentimes: total, plafondCentimes: poste.plafondMensuelCentimes)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(poste.nom, systemImage: poste.symbole)
                Spacer()
                Text(poste.plafondMensuelCentimes.map { "\(Montant.texte(total)) sur \(Montant.texte($0))" } ?? Montant.texte(total))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(etat == .depasse ? .red : .secondary)
            }
            if let plafond = poste.plafondMensuelCentimes, plafond > 0 {
                ProgressView(value: min(Double(total) / Double(plafond), 1))
                    .tint(couleur(etat))
            } else {
                Text("Hors plafond").font(.caption).foregroundStyle(.secondary)
            }
            if ecart != 0 {
                Text(ecart > 0 ? "▲ \(Montant.texte(ecart)) de plus que le mois précédent" : "▼ \(Montant.texte(-ecart)) de moins que le mois précédent")
                    .font(.caption2)
                    .foregroundStyle(ecart > 0 ? .orange : .green)
            }
        }
        .padding(.vertical, 4)
    }

    private func couleur(_ etat: EtatPlafond) -> Color {
        switch etat {
        case .large, .sansPlafond: .green
        case .proche: .orange
        case .depasse: .red
        }
    }
}

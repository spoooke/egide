import Charts
import EgideUI
import SwiftData
import SwiftUI

/// Six derniers mois : toutes les dépenses empilées par poste, puis un graphique par poste avec son plafond
/// (barre verte, orange dès 80 %, rouge au-delà) et sa moyenne sur les mois complets.
struct SixMoisView: View {
    @Query(sort: \Depense.date, order: .reverse) private var depenses: [Depense]
    @Query(sort: \Poste.ordre) private var postes: [Poste]

    var body: some View {
        let historique = Historique(depenses: depenses)
        List {
            Group {
                Section {
                    Chart {
                        ForEach(historique.mois, id: \.debut) { mois in
                            ForEach(postes) { poste in
                                BarMark(x: .value("Mois", mois.debut, unit: .month),
                                        y: .value("Montant", Double(mois.parPoste[poste.syncID] ?? 0) / 100))
                                    .foregroundStyle(by: .value("Poste", poste.nom))
                            }
                        }
                    }
                    .chartForegroundStyleScale(domain: postes.map(\.nom))
                    .chartXAxis { axeMois }
                    .chartYAxis { axeEuros }
                    .chartLegend(position: .bottom, alignment: .leading)
                    .frame(height: 260)
                    .padding(.vertical, 8)
                } header: {
                    Text("Tous les postes")
                } footer: {
                    Text("Le dernier mois est en cours. Les frais fixes ne sont pas comptés.")
                }

                ForEach(postes) { poste in
                    Section {
                        GraphiquePoste(poste: poste, historique: historique)
                    } header: {
                        Label(poste.nom, systemImage: poste.symbole)
                    }
                }
            }
            .egideRow()
        }
        .egideList()
        .egideTitre("Six derniers mois")
        .titreCompact()
    }
}

/// Barres d'un poste sur six mois, ligne pointillée du plafond, moyenne des mois complets.
private struct GraphiquePoste: View {
    let poste: Poste
    let historique: Historique

    var body: some View {
        let plafond = poste.plafondMensuelCentimes.flatMap { $0 > 0 ? $0 : nil }
        let moyenne = historique.moyenne(poste.syncID)
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(historique.mois, id: \.debut) { mois in
                    let total = mois.parPoste[poste.syncID] ?? 0
                    BarMark(x: .value("Mois", mois.debut, unit: .month), y: .value("Montant", Double(total) / 100))
                        .foregroundStyle(couleur(EtatPlafond(totalCentimes: total, plafondCentimes: plafond)))
                        .cornerRadius(4)
                }
                if let plafond {
                    RuleMark(y: .value("Plafond", Double(plafond) / 100))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                }
            }
            .chartXAxis { axeMois }
            .chartYAxis { axeEuros }
            .frame(height: 140)
            Text(resume(plafond: plafond, moyenne: moyenne))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func resume(plafond: Int?, moyenne: Int?) -> String {
        var parties: [String] = []
        if let moyenne { parties.append("Moyenne : \(Montant.texte(moyenne)) par mois") }
        parties.append(plafond.map { "plafond \(Montant.texte($0))" } ?? "hors plafond")
        return parties.joined(separator: " · ").capitalizedFirst
    }

    private func couleur(_ etat: EtatPlafond) -> Color {
        switch etat {
        case .sansPlafond: .accentColor
        case .large: .green
        case .proche: .orange
        case .depasse: .red
        }
    }
}

/// Initiale des mois (« oct. ») sous les barres.
@AxisContentBuilder
private var axeMois: some AxisContent {
    AxisMarks(values: .stride(by: .month)) { _ in
        AxisValueLabel(format: Date.FormatStyle(locale: Locale(identifier: "fr_FR")).month(.abbreviated), centered: true)
    }
}

/// Montants en euros entiers à gauche du graphique.
@AxisContentBuilder
private var axeEuros: some AxisContent {
    AxisMarks(position: .leading) { valeur in
        AxisGridLine()
        AxisValueLabel {
            if let euros = valeur.as(Double.self) { Text("\(Int(euros)) €") }
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

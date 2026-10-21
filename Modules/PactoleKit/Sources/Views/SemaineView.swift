import EgideUI
import SwiftUI

/// Accueil de l'onglet Money : reste de la semaine en grand, jauge et montant par jour jusqu'à dimanche.
struct SemaineView: View {
    let semaine: Semaine

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Cette semaine")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(Budget.euros(semaine.reste))
                    .font(.system(size: 72, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(semaine.etat == .depasse ? couleur : EgideTheme.encre)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(semaine.etat == .depasse ? "de dépassement" : "à dépenser")
                    .foregroundStyle(.secondary)
            }

            Gauge(value: semaine.proportionRestante) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            } minimumValueLabel: {
                Text("0")
            } maximumValueLabel: {
                Text(Budget.euros(semaine.plafond))
            }
            .tint(couleur)
            .padding(.horizontal)

            Label(parJourTexte, systemImage: "calendar")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical)
        .frame(maxWidth: .infinity)
    }

    private var couleur: Color {
        switch semaine.etat {
        case .large: .green
        case .serre: .orange
        case .depasse: .red
        }
    }

    private var parJourTexte: String {
        if semaine.etat == .depasse { return "Plus rien à dépenser d'ici dimanche" }
        if semaine.joursRestants == 1 { return "Dernier jour : \(Budget.euros(semaine.parJour))" }
        return "\(Budget.euros(semaine.parJour)) par jour pendant \(semaine.joursRestants) jours"
    }
}

#Preview("Large") {
    SemaineView(semaine: Semaine(plafond: 135, depense: 40, aujourdhui: .now))
}

#Preview("Dépassé") {
    SemaineView(semaine: Semaine(plafond: 135, depense: 150, aujourdhui: .now))
}

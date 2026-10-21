import SwiftUI

/// Ligne d'une dépense : poste, note, jour, montant.
struct DepenseRow: View {
    let depense: Depense
    let poste: Poste?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: poste?.symbole ?? "tag")
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(poste?.nom ?? "Poste supprimé")
                    if depense.rembourseLe != nil {
                        Text("remboursé").font(.caption2.weight(.semibold)).foregroundStyle(.green)
                    }
                    if depense.aVerifier {
                        Text("à vérifier").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                    }
                }
                .font(.body)
                Text(sousTitre)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(Montant.texte(depense.montantCentimes))
                .font(.body.monospacedDigit())
                .strikethrough(depense.rembourseLe != nil)
                .foregroundStyle(depense.rembourseLe != nil ? .secondary : .primary)
        }
    }

    private var sousTitre: String {
        let jour = depense.date.formatted(Date.FormatStyle(locale: Locale(identifier: "fr_FR")).weekday(.wide).day().month(.abbreviated))
        var parties = [jour]
        if !depense.commercant.isEmpty { parties.append(depense.commercant) }
        if !depense.note.isEmpty { parties.append(depense.note) }
        if depense.source != .manuel { parties.append(depense.source.libelle) }
        // Retrouvée sur le relevé bancaire.
        if !depense.banqueID.isEmpty && depense.source != .banque { parties.append("au relevé") }
        return parties.joined(separator: " · ")
    }
}

import EgideUI
import SwiftUI

/// Last backups, most recent first: when, how long, the outcome, and how long after the previous one.
/// A late backup (past the reminder) shows in orange, a failed one in red.
public struct HistoryList: View {
    let history: [Report.Entry]
    let schedule: Schedule
    var limit = 10

    public init(history: [Report.Entry], schedule: Schedule, limit: Int = 10) {
        self.history = history
        self.schedule = schedule
        self.limit = limit
    }

    public var body: some View {
        let regularity = Regularity.of(history, schedule: schedule)
        VStack(alignment: .leading, spacing: 10) {
            EgideSectionTitle("Historique")
            if history.isEmpty {
                Text("Aucune sauvegarde relevée pour l'instant.").foregroundStyle(.secondary)
            }
            ForEach(Array(history.prefix(limit).enumerated()), id: \.offset) { index, entry in
                if index > 0 { Divider() }
                row(entry, regularity[entry.end])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ entry: Report.Entry, _ regularity: Regularity?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(Wording.day(entry.end).capitalizedFirst).font(.body.weight(.medium))
                Spacer()
                Text(entry.succeeded ? (entry.duration ?? "réussie") : "échouée")
                    .foregroundStyle(entry.succeeded ? Color.secondary : Color.red)
                    .monospacedDigit()
            }
            if let failure = entry.failure {
                Text(failure).font(.footnote).foregroundStyle(.red)
            } else if let text = regularity?.text {
                Text(text.capitalizedFirst)
                    .font(.footnote)
                    .foregroundStyle((regularity?.daysLate ?? 0) > 0 ? Color.orange : Color.secondary)
            }
        }
    }
}

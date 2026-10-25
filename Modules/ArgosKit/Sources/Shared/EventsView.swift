import EgideUI
import SwiftUI

// Historique : problèmes apparus ou corrigés, nouveaux appareils, santé, réseau…

struct ArgosEvent: Codable, Hashable {
    let at: Date
    let title: String
    let message: String
    let priority: Int
}

extension APIClient {
    func events(limit: Int = 300) async throws -> [ArgosEvent] {
        try Self.decoder.decode([ArgosEvent].self, from: try await send("api/events?limit=\(limit)"))
    }
}

struct EventsView: View {
    @Environment(AppModel.self) private var model
    @State private var events: [ArgosEvent]?
    @State private var error: String?

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEEE d MMMM"
        return f
    }()

    private var days: [(String, [ArgosEvent])] {
        var out: [(String, [ArgosEvent])] = []
        for e in events ?? [] {
            let d = Self.dayFormat.string(from: e.at).capitalized
            if out.last?.0 == d { out[out.count - 1].1.append(e) } else { out.append((d, [e])) }
        }
        return out
    }

    var body: some View {
        List {
            Group {
                if let error { Text(error).foregroundStyle(.red) }
                if let events, events.isEmpty {
                    Text("Aucun événement pour l'instant : ils apparaîtront ici dès qu'un problème est détecté ou corrigé.")
                        .foregroundStyle(.secondary)
                }
                ForEach(days, id: \.0) { day, items in
                    Section(day) {
                        ForEach(items, id: \.self) { e in
                            HStack(alignment: .top, spacing: 10) {
                                // 1 = information (scan), 2 = corrigé, 3 = à surveiller, 4 = important
                                Image(systemName: e.priority >= 4 ? "exclamationmark.octagon.fill"
                                      : e.priority <= 1 ? "arrow.clockwise.circle.fill"
                                      : e.priority == 2 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(e.priority >= 4 ? .red : e.priority <= 1 ? .blue : e.priority == 2 ? .green : .orange)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(e.title).font(.subheadline.weight(.medium))
                                        Spacer()
                                        Text(e.at, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(e.message).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .egideRow()
        }
        .egideList()
        .egideTitre("Historique") {
            Button("Actualiser", systemImage: "arrow.clockwise") { Task { await load() } }
                .help("Recharger l'historique")
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let client = model.client else { return }
        do {
            events = try await client.events()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

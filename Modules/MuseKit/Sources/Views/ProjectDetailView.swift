import EgideUI
import SwiftData
import SwiftUI

struct ProjectDetailView: View {
    let project: Project
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var isRefreshing = false
    @State private var errorMessage: String?

    private struct SectionGroup: Identifiable {
        let id: Int
        let title: String
        let items: [RoadmapItem]
        var doneCount: Int { items.filter(\.isDone).count }
    }

    private var sections: [SectionGroup] {
        Dictionary(grouping: project.sortedItems, by: \.sectionIndex)
            .sorted { $0.key < $1.key }
            .map { SectionGroup(id: $0.key, title: $0.value.first?.section ?? "", items: $0.value) }
    }

    var body: some View {
        List {
            Group {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            RoadmapItemRow(item: item)
                                .swipeActions(edge: .trailing) {
                                    Button("Supprimer", systemImage: "trash", role: .destructive) {
                                        Task { await remove(item) }
                                    }
                                }
                                .contextMenu {
                                    Button("Supprimer de la roadmap", systemImage: "trash", role: .destructive) {
                                        Task { await remove(item) }
                                    }
                                }
                        }
                    } header: {
                        HStack {
                            Text(section.title)
                            Spacer()
                            if section.doneCount == section.items.count {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            } else {
                                Text("\(section.doneCount)/\(section.items.count)").monospacedDigit()
                            }
                        }
                    }
                }
                if let lastSyncedAt = project.lastSyncedAt {
                    Section {
                        LabeledContent("Actualisé", value: lastSyncedAt.formatted(.relative(presentation: .named)))
                        if let fileName = project.sourceFileName {
                            LabeledContent("Fichier", value: fileName)
                        }
                    }
                }
            }
            .egideRow()
        }
        .egideList()
        .egideTitre(project.name) {
            Button {
                Task { await refresh() }
            } label: {
                if isRefreshing {
                    ProgressView()
                } else {
                    Label("Actualiser", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isRefreshing)
        }
        .refreshable { await refresh() }
        // Actualisation automatique à l'ouverture et au retour dans l'app.
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    /// Retire la ligne du fichier roadmap : elle disparaît sur tous les appareils.
    private func remove(_ item: RoadmapItem) async {
        do {
            try await RoadmapSync.removeItem(item, from: project, context: context)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refresh() async {
        guard !isRefreshing, project.sourceBookmark != nil else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await RoadmapSync.refresh(project, context: context)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct RoadmapItemRow: View {
    let item: RoadmapItem

    var body: some View {
        Button {
            item.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isDone ? Color.green : Color.secondary)
                // `.init` : affiche le gras et le code Markdown du fichier.
                Text(.init(item.text))
                    .foregroundStyle(item.isDone ? .secondary : .primary)
                    .strikethrough(item.isDone)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item.phoneOverride != nil {
                    Image(systemName: "iphone")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Modifié sur l'iPhone")
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: item.isDone)
    }
}

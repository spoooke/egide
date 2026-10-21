import EgideUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ProjectsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Project.createdAt) private var projects: [Project]
    @State private var isImporting = false
    @State private var errorMessage: String?

    private static let roadmapTypes: [UTType] =
        [.plainText, UTType("net.daringfireball.markdown")].compactMap { $0 }

    var body: some View {
        List {
            Group {
                ForEach(projects) { project in
                    NavigationLink(value: project) {
                        ProjectRow(project: project)
                    }
                }
                .onDelete { offsets in
                    for index in offsets { context.delete(projects[index]) }
                }
            }
            .egideRow()
        }
        .egideList()
        .overlay {
            if projects.isEmpty {
                ContentUnavailableView {
                    Label("Aucun projet", systemImage: "folder")
                } description: {
                    Text("Importe un fichier roadmap (ex. ROADMAP.md) depuis l'app Fichiers.")
                } actions: {
                    Button("Importer une roadmap") { isImporting = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .egideTitre("Projets")
        .toolbar {
            Button {
                isImporting = true
            } label: {
                Label("Importer une roadmap", systemImage: "square.and.arrow.down")
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: Self.roadmapTypes) { result in
            switch result {
            case .success(let url):
                Task {
                    do {
                        try await RoadmapSync.importRoadmap(from: url, in: context)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .alert("Import impossible", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

private struct ProjectRow: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(project.name).font(.headline)
                Spacer()
                Text("\(project.doneCount)/\(project.totalCount)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(project.doneCount), total: Double(max(project.totalCount, 1)))
        }
        .padding(.vertical, 4)
    }
}

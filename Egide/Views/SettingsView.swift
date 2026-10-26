import EgideUI
import SwiftUI

/// Réglages d'Égide : ordre et visibilité des apps, informations sur l'app.
/// Chaque module ajoutera ici sa propre section (connexion Argos, appairage Hermès, plafonds Money…).
struct SettingsView: View {
    @Binding var layout: TabLayout
    @State private var exportDocument: GlobalBackupDocument?
    @State private var isImporting = false
    @State private var backupMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(layout.order) { module in
                    Toggle(isOn: Binding(get: { !layout.hidden.contains(module) },
                                         set: { layout.setHidden(module, !$0) })) {
                        Label {
                            Text(module.title)
                        } icon: {
                            Image(module.iconName).resizable().egideIconFrame(28)
                        }
                    }
                }
                .onMove { layout.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("Apps de l'accueil")
            } footer: {
                Text("Fais glisser pour changer l'ordre des icônes sur l'accueil ; décoche une app pour la masquer.")
            }
            .egideRow()

            Section {
                Button("Ordre par défaut") { layout = .standard }
                    .disabled(layout == .standard)
            }
            .egideRow()

            Section {
                EgideChoixPalette()
            } header: {
                Text("Apparence")
            } footer: {
                Text("Night City : fond noir, jaune néon et cyan, angles coupés. Toujours en mode sombre.")
            }
            .egideRow()

            Section {
                Button("Tout sauvegarder", systemImage: "square.and.arrow.up") {
                    do {
                        exportDocument = GlobalBackupDocument(data: try GlobalBackup.make(layout: layout).encoded())
                    } catch {
                        backupMessage = "Échec de la sauvegarde : \(error.localizedDescription)"
                    }
                }
                Button("Tout restaurer", systemImage: "clock.arrow.circlepath") { isImporting = true }
            } header: {
                Text("Sauvegarde de tous les modules")
            } footer: {
                Text(backupMessage ?? "Un fichier avec l'ordre des apps et les données de chaque module (idées de Muse…). Aucun secret : la connexion Argos et l'appairage Hermès sont à refaire sur un nouvel iPhone. La restauration n'efface rien.")
            }
            .egideRow()

            Section("À propos") {
                LabeledContent("Version", value: Self.version)
                LabeledContent("Identifiant", value: Bundle.main.bundleIdentifier ?? "—")
            }
            .egideRow()
        }
        .environment(\.editMode, .constant(.active))
        .egideList()
        .navigationTitle("Réglages")
        .fileExporter(
            isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
            document: exportDocument,
            contentType: .json,
            defaultFilename: GlobalBackup.defaultFileName()
        ) { result in
            switch result {
            case .success: backupMessage = "Sauvegarde enregistrée."
            case .failure(let error): backupMessage = "Échec de la sauvegarde : \(error.localizedDescription)"
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            restore(result)
        }
    }

    private func restore(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let backup = try GlobalBackup.decode(try Data(contentsOf: url))
            backupMessage = backup.restore(into: &layout).joined(separator: "\n")
        } catch {
            backupMessage = "Fichier illisible : ce n'est pas une sauvegarde d'Égide."
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

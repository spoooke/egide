import EgideUI
import SwiftData
import SwiftUI

struct SyncSettingsView: View {
    private enum FilePurpose { case folder, backup }

    @Environment(\.modelContext) private var context
    @State private var sync = SyncService.shared
    /// Usage du sélecteur de fichiers. Gardé après sa fermeture : SwiftUI ferme le sélecteur (isPicking = false)
    /// avant d'appeler le traitement du fichier choisi.
    @State private var purpose: FilePurpose = .folder
    @State private var isPicking = false
    @State private var backup: BackupDocument?
    @State private var backupMessage: String?

    var body: some View {
        Form {
            Group {
                Section {
                    if let folderName = sync.folderName {
                        LabeledContent("Dossier", value: folderName)
                        Button("Changer de dossier") { pick(.folder) }
                    } else {
                        Button {
                            pick(.folder)
                        } label: {
                            Label("Choisir le dossier de synchro", systemImage: "folder.badge.plus")
                        }
                    }
                } header: {
                    Text("Dossier partagé")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Choisis le même dossier iCloud Drive sur le Mac et sur l'iPhone, par exemple iCloud Drive › Muse. Les rappels restent propres à chaque appareil.")
                        // Erreur au choix du dossier (la section « Synchroniser » n'existe pas encore).
                        if !sync.isConfigured, let lastError = sync.lastError {
                            Text(lastError).foregroundStyle(.red)
                        }
                    }
                }

                if sync.isConfigured {
                    Section {
                        Button {
                            Task { await sync.sync() }
                        } label: {
                            HStack {
                                Label("Synchroniser maintenant", systemImage: "arrow.triangle.2.circlepath")
                                Spacer()
                                if sync.isSyncing { ProgressView() }
                            }
                        }
                        .disabled(sync.isSyncing)

                        if let lastSyncAt = sync.lastSyncAt {
                            LabeledContent("Dernière synchro", value: lastSyncAt.formatted(.relative(presentation: .named)))
                        }
                        LabeledContent("Cet appareil", value: sync.deviceName)
                        LabeledContent("Autres appareils",
                                       value: sync.otherDevices.isEmpty ? "aucun pour l'instant" : sync.otherDevices.joined(separator: ", "))
                    } footer: {
                        if let lastError = sync.lastError {
                            Text(lastError).foregroundStyle(.red)
                        }
                    }

                    Section {
                        Button("Arrêter la synchro", role: .destructive) { sync.stopSyncing() }
                    } footer: {
                        Text("Les idées restent sur cet appareil.")
                    }
                }

                // Disponible même sans synchro.
                Section {
                    Button {
                        do {
                            backup = try Backup.export(from: context)
                        } catch {
                            backupMessage = "Échec de l'export : \(error.localizedDescription)"
                        }
                    } label: {
                        Label("Exporter mes idées", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        pick(.backup)
                    } label: {
                        Label("Restaurer une sauvegarde", systemImage: "clock.arrow.circlepath")
                    }
                } header: {
                    Text("Sauvegarde")
                } footer: {
                    Text(backupMessage ?? "Un fichier avec toutes tes idées (texte, état, tags, priorité). Les images n'y sont pas. La restauration ajoute les idées absentes et ne remplace que par plus récent.")
                }
            }
            .egideRow()
        }
        .egideList()
        .formStyle(.grouped)
        .egideTitre("Synchro")
        .fileExporter(
            isPresented: Binding(get: { backup != nil }, set: { if !$0 { backup = nil } }),
            document: backup,
            contentType: .json,
            defaultFilename: Backup.defaultFileName()
        ) { result in
            switch result {
            case .success: backupMessage = "Sauvegarde enregistrée."
            case .failure(let error): backupMessage = "Échec de l'export : \(error.localizedDescription)"
            }
        }
        // Un seul sélecteur de fichiers par écran (SwiftUI n'en gère pas deux) : dossier de synchro ou sauvegarde.
        .fileImporter(isPresented: $isPicking, allowedContentTypes: purpose == .backup ? [.json] : [.folder]) { result in
            switch purpose {
            case .folder:
                if case .success(let url) = result {
                    Task { await sync.chooseFolder(url) }
                }
            case .backup:
                restore(result)
            }
        }
    }

    private func pick(_ purpose: FilePurpose) {
        self.purpose = purpose
        isPicking = true
    }

    private func restore(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let count = try Backup.restore(try Data(contentsOf: url), into: context)
            backupMessage = count == 0 ? "Rien à restaurer : tout est déjà à jour." : "\(count) idée(s) restaurée(s)."
        } catch {
            backupMessage = "Fichier illisible : ce n'est pas une sauvegarde Muse."
        }
    }
}

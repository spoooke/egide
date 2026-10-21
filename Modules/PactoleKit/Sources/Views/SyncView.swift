import EgideUI
import SwiftUI

/// Écran « Synchro » : dossier iCloud Drive partagé entre l'iPhone et le Mac, état, synchro manuelle.
struct SyncView: View {
    @State private var sync = PactoleSync.shared
    @State private var choix = false

    var body: some View {
        Form {
            Group {
                Section {
                    if let folderName = sync.folderName {
                        LabeledContent("Dossier", value: folderName)
                        Button("Changer de dossier") { choix = true }
                    } else {
                        Button("Choisir le dossier de synchro", systemImage: "folder.badge.plus") { choix = true }
                    }
                } header: {
                    Text("Dossier partagé")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Choisis le même dossier iCloud Drive sur l'iPhone et sur le Mac, par exemple iCloud Drive › Money. Chaque appareil y écrit ses dépenses et lit celles des autres.")
                        if !sync.isConfigured, let erreur = sync.lastError { Text(erreur).foregroundStyle(.red) }
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
                        if let date = sync.lastSyncAt {
                            LabeledContent("Dernière synchro", value: date.formatted(.relative(presentation: .named)))
                        }
                        LabeledContent("Cet appareil", value: sync.deviceName)
                        LabeledContent("Autres appareils", value: sync.otherDevices.isEmpty ? "aucun pour l'instant" : sync.otherDevices.joined(separator: ", "))
                    } footer: {
                        if let erreur = sync.lastError { Text(erreur).foregroundStyle(.red) }
                    }

                    Section {
                        Button("Arrêter la synchro", role: .destructive) { sync.stopSyncing() }
                    } footer: {
                        Text("Les dépenses restent sur cet appareil.")
                    }
                }
            }
            .egideRow()
        }
        .egideList()
        .formStyle(.grouped)
        .egideTitre("Synchro")
        .fileImporter(isPresented: $choix, allowedContentTypes: [.folder]) { resultat in
            if case .success(let url) = resultat { Task { await sync.chooseFolder(url) } }
        }
    }
}

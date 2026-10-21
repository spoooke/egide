import EgideUI
import SwiftUI

struct AddPhoneView: View {
    let onCreated: (String) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var platform = "ios"
    @State private var version = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        Text("Les apps ne peuvent pas inspecter un téléphone de l'extérieur : Argos te guide point par point dans les réglages, et tu réponds à chaque question.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Section {
                        TextField("Nom", text: $name, prompt: Text("Mon iPhone"))
                        Picker("Système", selection: $platform) {
                            Text("iOS (iPhone)").tag("ios")
                            Text("Android").tag("android")
                        }
                        TextField("Version (facultatif)", text: $version, prompt: Text("ex. 26.1"))
                    }
                    if let error {
                        Text(error).foregroundStyle(.red)
                    }
                }
                .egideRow()
            }
            .egideList()
            .formStyle(.grouped)
            .navigationTitle("Ajouter un téléphone")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Commencer") { Task { await create() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }

    private func create() async {
        guard let client = model.client else { return }
        saving = true
        defer { saving = false }
        do {
            let id = try await client.createPhone(name: name, platform: platform, osVersion: version)
            await model.refreshDevices()
            dismiss()
            onCreated(id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct AlertsView: View {
    @Environment(AppModel.self) private var model
    @State private var settings: ServerSettings?
    @State private var message: (String, Bool)?

    var body: some View {
        Form {
            Group {
                Section {
                    Text("Argos t'envoie une notification quand un problème apparaît, quand il est corrigé, et quand un nouvel appareil rejoint Argos.")
                    Text("1. Installe l'app gratuite **ntfy**.\n2. Dans ntfy, touche **+** et abonne-toi au sujet ci-dessous (serveur ntfy.sh).\n3. Touche « Envoyer un test ».")
                        .font(.callout)
                }
                if let binding = Binding($settings) {
                    Section {
                        HStack {
                            TextField("Sujet ntfy", text: binding.ntfyTopic)
                                .autocorrectionDisabled()
                            Button("Copier", systemImage: "doc.on.doc") {
                                Clipboard.copy(binding.wrappedValue.ntfyTopic)
                                message = ("Sujet copié.", true)
                            }
                            .labelStyle(.iconOnly)
                        }
                    } header: {
                        Text("Sujet")
                    } footer: {
                        Text("Garde-le secret : sur ntfy.sh, toute personne qui connaît ce nom peut lire tes alertes. Vide = alertes désactivées.")
                    }
                    Section("Avancé") {
                        TextField("Serveur ntfy", text: binding.ntfyServer).autocorrectionDisabled()
                        TextField("Adresse du dashboard", text: binding.dashboardUrl).autocorrectionDisabled()
                    }
                    Section {
                        Button("Enregistrer") { Task { await save(test: false) } }
                        Button("Envoyer un test") { Task { await save(test: true) } }
                        if let message {
                            Text(message.0).foregroundStyle(message.1 ? .green : .red)
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .egideRow()
        }
        .egideList()
        .formStyle(.grouped)
        .egideTitre("Alertes")
        .task {
            do { settings = try await model.client?.settings() } catch { message = (error.localizedDescription, false) }
        }
    }

    private func save(test: Bool) async {
        guard let client = model.client, let s = settings else { return }
        do {
            settings = try await client.saveSettings(s)
            if test { try await client.testNotification() }
            message = (test ? "Notification envoyée : vérifie ton téléphone." : "Enregistré.", true)
        } catch {
            message = (error.localizedDescription, false)
        }
    }
}

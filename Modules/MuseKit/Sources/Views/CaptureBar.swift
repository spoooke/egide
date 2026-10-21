import EgideUI
import SwiftUI

/// Champ de saisie toujours visible en bas de l'écran.
/// Il prend le focus à l'ouverture et à chaque retour dans l'app,
/// et la touche Retour enregistre l'idée. Le bouton clavier (ou un glissement
/// sur la liste) baisse le clavier.
struct CaptureBar: View {
    let onSave: (String) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    /// Faux quand un autre écran est affiché par-dessus : pas de clavier surprise au retour dans l'app.
    @State private var isVisible = false
    @State private var navigation = AppNavigation.shared

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Nouvelle idée…", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .focused($isFocused)
                .submitLabel(.done)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(EgideTheme.carte, in: .rect(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(EgideTheme.contour))
                .onChange(of: text) { _, newValue in
                    // Champ multiligne : Retour insère « \n », on l'intercepte pour enregistrer.
                    if newValue.contains("\n") {
                        text = newValue.replacingOccurrences(of: "\n", with: "")
                        save()
                    }
                }

            if isFocused {
                Button {
                    isFocused = false
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 22))
                        .frame(height: 34)
                }
                .tint(.secondary)
                .accessibilityLabel("Baisser le clavier")
            }

            Button(action: save) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34))
            }
            .disabled(!canSave)
            .accessibilityLabel("Enregistrer l'idée")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear {
            isVisible = true
            isFocused = true
        }
        .onDisappear { isVisible = false }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && isVisible { isFocused = true }
        }
        .onChange(of: navigation.captureRequests) {
            // Laisse le temps à la liste de réapparaître si un autre écran était ouvert.
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                isFocused = true
            }
        }
    }

    private func save() {
        guard canSave else { return }
        onSave(text)
        text = ""
        // La liste se met à jour juste après l'enregistrement et fait perdre le focus :
        // on le redonne au tour suivant pour garder le clavier ouvert.
        Task { @MainActor in isFocused = true }
    }
}

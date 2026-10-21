import AppIntents
import SwiftUI
import WidgetKit

/// Bouton 💡 pour l'écran verrouillé et le Centre de contrôle : ouvre l'onglet Muse sur le champ de saisie.
struct NewIdeaControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.spoooke.egide.controls.newIdea") {
            ControlWidgetButton(action: OpenCaptureIntent()) {
                Label("Nouvelle idée", systemImage: "lightbulb")
            }
        }
        .displayName("Nouvelle idée")
        .description("Ouvre Égide prête à noter une idée.")
    }
}

@main
struct EgideControlsBundle: WidgetBundle {
    var body: some Widget {
        NewIdeaControl()
    }
}

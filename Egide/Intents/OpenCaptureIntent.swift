import AppIntents

/// Ouvre Égide sur l'onglet Muse, prête à noter une idée.
/// Compilé aussi dans l'extension EgideControls : le contrôle de l'écran verrouillé
/// l'utilise, et iOS l'exécute dans l'app (pas de demande « Ouvrir dans Égide ? »).
struct OpenCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Noter une idée"
    static let description = IntentDescription("Ouvre Égide sur l'onglet Muse, prête à noter une idée.")
    static let openAppWhenRun = true
    /// Utilisée seulement par le contrôle : ni Siri, ni Raccourcis, ni Spotlight.
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !EGIDE_EXTENSION
        AppRouter.shared.open(.module(.muse), path: ["capture"])
        #endif
        return .result()
    }
}

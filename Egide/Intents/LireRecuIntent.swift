import AppIntents
import PactoleKit
import UniformTypeIdentifiers

/// Action Raccourcis « Lire un reçu » : ouvre Égide sur la saisie Money pré-remplie avec le reçu
/// (capture, photo, PDF PayPal ou PayByPhone, texte d'un mail). Prévue pour un raccourci affiché
/// dans la feuille de partage.
struct LireRecuIntent: AppIntent {
    static let title: LocalizedStringResource = "Lire un reçu"
    static let description = IntentDescription("Ouvre Pactole (Égide) sur une dépense pré-remplie avec le montant, la date et le commerçant du reçu.")
    static let openAppWhenRun = true

    @Parameter(title: "Reçu", supportedContentTypes: [.pdf, .image, .plainText, .html, .text])
    var recu: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Lire le reçu \(\.$recu)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        PactoleKit.recevoirRecu(data: recu.data, nomFichier: recu.filename, typeIdentifier: recu.type?.identifier)
        AppRouter.shared.open(.module(.money))
        return .result()
    }
}

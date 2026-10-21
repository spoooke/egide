import AppIntents
import PactoleKit

/// Action Raccourcis « Ajouter une dépense » : enregistre un paiement dans Money sans ouvrir Égide.
/// Prévue pour l'automatisation « Transaction » de Raccourcis (Wallet) : commerçant, montant et carte
/// viennent de l'entrée du raccourci. Classement automatique, file « À vérifier », anti-doublon.
struct AjouterDepenseIntent: AppIntent {
    static let title: LocalizedStringResource = "Ajouter une dépense"
    static let description = IntentDescription("Enregistre un paiement dans Pactole (Égide), classé automatiquement, sans ouvrir l'app.")
    static let openAppWhenRun = false

    @Parameter(title: "Commerçant")
    var commercant: String

    @Parameter(title: "Montant", description: "Par exemple 13,00 €")
    var montant: String

    @Parameter(title: "Carte")
    var carte: String?

    @Parameter(title: "Date", description: "Maintenant si vide")
    var date: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("Ajouter \(\.$montant) chez \(\.$commercant)") {
            \.$carte
            \.$date
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message = try PactoleKit.ajouterPaiement(commercant: commercant, montant: montant, carte: carte, date: date)
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }
}

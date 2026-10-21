import Foundation

/// Ce que l'outil en ligne de commande dit ou demande, selon le système : version Mac.
enum Console {
    static let optionSignature = "--gatekeeper"
    static let annonceSignature = "Gatekeeper demandé : macOS peut interroger Apple sur la signature."
    static let ciblesPropres = "app | image disque | paquet"
    static let ciblesSignature = "une app, une image disque, un paquet, une archive ou un fichier du Mac"

    /// Une personne est au clavier (l'accord pour la lecture par IA ne peut venir que d'elle).
    static var interactif: Bool { isatty(STDIN_FILENO) == 1 }

    /// Saisie qui ne s'affiche pas (ni à l'écran, ni dans l'historique du shell).
    static func saisieMasquee(_ question: String) -> String? {
        getpass(question).map { String(cString: $0) }
    }
}

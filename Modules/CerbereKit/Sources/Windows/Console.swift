import Foundation
import WinSDK

/// Ce que l'outil en ligne de commande dit ou demande, selon le système : version Windows.
enum Console {
    static let optionSignature = "--authenticode"
    static let annonceSignature = "Authenticode demandé : Windows peut interroger l'autorité de certification du signataire."
    static let ciblesPropres = "programme .exe/.dll | paquet .msi"
    static let ciblesSignature = "un programme (.exe, .dll), un paquet .msi, une archive ou un fichier du PC"

    /// Une personne est au clavier (l'accord pour la lecture par IA ne peut venir que d'elle) : l'entrée est une console.
    static var interactif: Bool {
        var mode: DWORD = 0
        return GetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), &mode)
    }

    /// Saisie qui ne s'affiche pas : l'écho de la console est coupé le temps de la saisie.
    static func saisieMasquee(_ question: String) -> String? {
        let entree = GetStdHandle(STD_INPUT_HANDLE)
        var mode: DWORD = 0
        guard GetConsoleMode(entree, &mode) else { return nil }
        FileHandle.standardError.write(Data(question.utf8))
        _ = SetConsoleMode(entree, mode & ~DWORD(ENABLE_ECHO_INPUT))
        defer {
            _ = SetConsoleMode(entree, mode)
            FileHandle.standardError.write(Data("\n".utf8))
        }
        return readLine(strippingNewline: true)
    }
}

import CoreGraphics
import Foundation
import Testing
@testable import IrisKit

/// Tickets, factures et documents inventés : textes et commerces fictifs, rien de réel.
struct IrisClasseurTests {
    private static func page(_ lignes: [String], largeur: Int = 1240, hauteur: Int = 1754) -> IrisPage {
        IrisPage(jpeg: Data(), largeur: largeur, hauteur: hauteur,
                 lignes: lignes.map { IrisLigne(texte: $0, boite: CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.02)) })
    }

    static let ticket = [
        "ÉPICERIE DU COIN", "12 rue d'Essai", "SIRET 000 000 000 00000",
        "Pain 1,20", "Lait 0,95", "Pommes 2,40", "Café 3,10", "Chocolat 1,85",
        "TOTAL 9,50 €", "TVA 5,5% 0,50", "CB SANS CONTACT 9,50", "17/10/2026 18:42", "Caisse 2", "MERCI DE VOTRE VISITE",
    ]

    static let facture = [
        "Atelier Exemple SARL", "SIRET 000 000 000 00000", "TVA intracom FR00 000000000",
        "FACTURE", "N° de facture : F-2026-0042", "Date de facture : 17/10/2026",
        "Client : Entreprise Essai", "Prestation de test 100,00", "Total HT 100,00 €", "TVA 20 % 20,00 €", "Total TTC 120,00 €",
        "Échéance : 16/11/2026", "IBAN FR76 0000 0000 0000 0000 0000 000",
    ]

    static let lettre = [
        "Madame, Monsieur,", "Nous vous informons que la réunion d'essai aura lieu le 20 octobre.",
        "Merci de confirmer votre présence.", "Veuillez agréer nos salutations distinguées.",
    ]

    @Test func ticketEtroit() {
        #expect(IrisClasseur.genre([Self.page(Self.ticket, largeur: 600, hauteur: 1900)]) == .ticket)
    }

    @Test func ticketPhotographieLarge() {
        // Ticket photographié sans être recadré : la forme ne compte pas, le texte suffit.
        #expect(IrisClasseur.genre([Self.page(Self.ticket)]) == .ticket)
    }

    @Test func facture() {
        #expect(IrisClasseur.genre([Self.page(Self.facture)]) == .facture)
    }

    @Test func factureSurDeuxPages() {
        #expect(IrisClasseur.genre([Self.page(Array(Self.facture.prefix(6))), Self.page(Array(Self.facture.dropFirst(6)))]) == .facture)
    }

    @Test func factureMajusculesSansAccents() {
        #expect(IrisClasseur.genre([Self.page(Self.facture.map { $0.uppercased().folding(options: .diacriticInsensitive, locale: nil) })]) == .facture)
    }

    @Test func lettreResteDocument() {
        #expect(IrisClasseur.genre([Self.page(Self.lettre)]) == nil)
        #expect(IrisClasseur.genre([Self.page(Self.lettre)], choix: .auto) == .document)
    }

    @Test func pageSansTexte() {
        #expect(IrisClasseur.genre([Self.page([])]) == nil)
        #expect(IrisClasseur.genre([]) == nil)
    }

    @Test func indicesMelesHesitation() {
        // Un mot de chaque côté, sans avance nette : Document.
        #expect(IrisClasseur.genre([Self.page(["Facture", "Total 12,00", "Caisse"])]) == nil)
    }

    @Test func choixForcePasseAvant() {
        #expect(IrisClasseur.genre([Self.page(Self.facture)], choix: .ticket) == .ticket)
        #expect(IrisClasseur.genre([Self.page(Self.lettre)], choix: .facture) == .facture)
        #expect(IrisClasseur.genre([Self.page(Self.ticket)], choix: .document) == .document)
    }

    @Test func choixTitres() {
        #expect(IrisChoixGenre.allCases.map(\.titre) == ["Auto", "Ticket", "Facture", "Document"])
    }
}

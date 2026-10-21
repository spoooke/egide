import Foundation
import Testing
@testable import IrisKit

struct IrisKitTests {
    @Test func routes() {
        #expect(IrisRoute(path: []) == .home)
        #expect(IrisRoute(path: ["reglages"]) == .reglages)
        #expect(IrisRoute(path: ["inconnu"]) == .home)
    }

    @Test func adresses() {
        #expect(IrisReglages.adresseValide("prenom.nom@example.com"))
        #expect(IrisReglages.adresseValide("a+b@sous.example.org"))
        #expect(!IrisReglages.adresseValide(""))
        #expect(!IrisReglages.adresseValide("sans-arobase.example.com"))
        #expect(!IrisReglages.adresseValide("a@b@example.com"))
        #expect(!IrisReglages.adresseValide("@example.com"))
        #expect(!IrisReglages.adresseValide("a@example"))
        #expect(!IrisReglages.adresseValide("a@.com"))
        #expect(!IrisReglages.adresseValide("a@example.c"))
        #expect(!IrisReglages.adresseValide("a b@example.com"))
        #expect(!IrisReglages.adresseValide("Nom <a@example.com>"))
    }

    @Test func destinataires() {
        var reglages = IrisReglages()
        #expect(!reglages.complet)
        reglages.destinataires = [" a@example.com ", ""]
        #expect(reglages.adresses == ["a@example.com"])
        #expect(reglages.complet)
        reglages.destinataires = ["a@example.com", "A@Example.com"]
        #expect(reglages.adresses == ["a@example.com"])
        reglages.destinataires = ["a@example.com", "incomplet@"]
        #expect(!reglages.complet)
    }

    @Test func objet() {
        var reglages = IrisReglages()
        #expect(reglages.objetEffectif == "Scan")
        reglages.objet = "  "
        #expect(reglages.objetEffectif == "Scan")
        reglages.objet = " Reçu "
        #expect(reglages.objetEffectif == "Reçu")
    }

    @Test func enregistrement() throws {
        let stockage = try #require(UserDefaults(suiteName: "IrisKitTests-\(UUID().uuidString)"))
        #expect(IrisReglages.charger(stockage) == IrisReglages())
        let reglages = IrisReglages(destinataires: ["a@example.com", "b@example.org"], objet: "Reçu", garderDansPhotos: true)
        reglages.enregistrer(stockage)
        #expect(IrisReglages.charger(stockage) == reglages)
    }
}

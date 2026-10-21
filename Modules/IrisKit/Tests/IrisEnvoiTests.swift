import Foundation
import MessageUI
import Testing
@testable import IrisKit

struct IrisEnvoiTests {
    private let scan = IrisScan(url: URL(filePath: "/tmp/Ticket 2026-10-16.pdf"), date: .now)

    @Test func objet() {
        var reglages = IrisReglages(destinataires: ["a@example.com"])
        #expect(IrisMail.objet(reglages, scan: scan) == "Scan · Ticket 2026-10-16")
        reglages.objet = " Reçu "
        #expect(IrisMail.objet(reglages, scan: scan) == "Reçu · Ticket 2026-10-16")
        reglages.objet = ""
        #expect(IrisMail.objet(reglages, scan: scan) == "Scan · Ticket 2026-10-16")
    }

    @Test func voie() {
        let complet = IrisReglages(destinataires: ["a@example.com", "b@example.org"])
        #expect(IrisMail.voie(complet, peutEnvoyer: true) == .mail)
        #expect(IrisMail.voie(complet, peutEnvoyer: false) == .secours)
        #expect(IrisMail.voie(IrisReglages(), peutEnvoyer: true) == .reglages)
        #expect(IrisMail.voie(IrisReglages(), peutEnvoyer: false) == .reglages)
        let incomplet = IrisReglages(destinataires: ["a@example.com", "incomplet@"])
        #expect(IrisMail.voie(incomplet, peutEnvoyer: true) == .reglages)
    }

    @Test func resultats() {
        #expect(IrisResultat(MFMailComposeResult.sent) == .envoye)
        #expect(IrisResultat(MFMailComposeResult.cancelled) == .annule)
        #expect(IrisResultat(MFMailComposeResult.saved) == .brouillon)
        #expect(IrisResultat(MFMailComposeResult.failed) == .echec)
    }

    private func historique() throws -> IrisHistorique {
        IrisHistorique(try #require(UserDefaults(suiteName: "IrisEnvoiTests-\(UUID().uuidString)")))
    }

    @Test func enregistrement() throws {
        let historique = try historique()
        #expect(historique.liste().isEmpty)
        let envoi = IrisEnvoi(nom: "Ticket 2026-10-16", date: Date(timeIntervalSince1970: 1_000), pages: 2, resultat: .envoye)
        historique.ajouter(envoi)
        #expect(historique.liste() == [envoi])
    }

    @Test func ordre() throws {
        let historique = try historique()
        historique.ajouter(IrisEnvoi(nom: "Premier", pages: 1, resultat: .annule))
        historique.ajouter(IrisEnvoi(nom: "Deuxième", pages: 1, resultat: .brouillon))
        historique.ajouter(IrisEnvoi(nom: "Troisième", pages: 3, resultat: .echec))
        #expect(historique.liste().map(\.nom) == ["Troisième", "Deuxième", "Premier"])
        #expect(historique.liste().map(\.resultat) == [.echec, .brouillon, .annule])
    }

    @Test func limite() throws {
        let historique = try historique()
        for i in 0..<(IrisHistorique.limite + 5) {
            historique.ajouter(IrisEnvoi(nom: "Scan \(i)", pages: 1, resultat: .envoye))
        }
        let liste = historique.liste()
        #expect(liste.count == IrisHistorique.limite)
        #expect(liste.first?.nom == "Scan \(IrisHistorique.limite + 4)")
        #expect(liste.last?.nom == "Scan 5")
    }

    /// L'historique enregistré ne contient aucune adresse.
    @Test func sansAdresse() throws {
        let stockage = try #require(UserDefaults(suiteName: "IrisEnvoiTests-\(UUID().uuidString)"))
        IrisReglages(destinataires: ["a@example.com"]).enregistrer(stockage)
        IrisHistorique(stockage).ajouter(IrisEnvoi(nom: "Ticket 2026-10-16", pages: 1, resultat: .envoye))
        let data = try #require(stockage.data(forKey: IrisHistorique.cle))
        #expect(!String(decoding: data, as: UTF8.self).contains("@"))
    }
}

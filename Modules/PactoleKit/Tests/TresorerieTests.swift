import Foundation
import SwiftData
import Testing
@testable import PactoleKit

struct TresorerieTests {
    private let cal = Calendar.francais
    private func date(_ m: Int, _ j: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: 2026, month: m, day: j, hour: h))!
    }

    @Test func echeancesRameneesAuDernierJour() {
        #expect(Tresorerie.echeance(jour: 31, mois: date(2, 10), calendrier: cal) == cal.startOfDay(for: date(2, 28)))
        #expect(Tresorerie.prochaineEcheance(jour: 6, apres: date(10, 6), calendrier: cal) == cal.startOfDay(for: date(11, 6)))
        #expect(Tresorerie.echeances(jour: 6, apres: date(10, 25), jusqua: date(11, 6, 8), calendrier: cal) == 1)
    }

    /// Point à −300 € le 25 octobre, loyer le 1er, paie au plus tard le 6.
    @Test func decouvertPuisPaie() {
        let loyer = FraisFixe(nom: "Loyer", montantCentimes: 700_00, jour: 1, categorie: .logement)
        let annuel = FraisFixe(nom: "Assurance", montantCentimes: 300_00, jour: 2, categorie: .assurance)
        annuel.moisAnnuel = 11
        let avant = Depense(montantCentimes: 50_00, posteID: "courses", date: date(10, 24))
        let apres = Depense(montantCentimes: 40_00, posteID: "courses", date: date(10, 27))
        let t = Tresorerie.calculer(solde: -300_00, datePoint: date(10, 25), jourPaie: 6, salaire: 2_000_00, marge: 100_00,
                                    depenses: [avant, apres], frais: [loyer, annuel], maintenant: date(10, 28), calendrier: cal)
        #expect(t.soldeAujourdhui == -340_00)
        #expect(t.prochainePaie == cal.startOfDay(for: date(11, 6)))
        #expect(t.soldeAvantPaie == -1_040_00)
        #expect(t.aDepenserAvantPaie < 0)
        // 6 nov. → 6 déc. : −1 040 + 2 000 − loyer du 1er déc. − 100 de marge.
        #expect(t.aDepenserCycleSuivant == 160_00)
        #expect(t.joursCycleSuivant == 30)
        #expect(Tresorerie.parSemaine(t.aDepenserCycleSuivant, jours: 30) == 37_00)
    }

    @Test func virementsAjoutesAuSolde() {
        let virements = [Virement(date: date(10, 24), montantCentimes: 80_00),
                         Virement(date: date(10, 26), montantCentimes: 50_00), Virement(date: date(10, 27), montantCentimes: 50_00)]
        let t = Tresorerie.calculer(solde: -300_00, datePoint: date(10, 25), jourPaie: 6, salaire: 0, marge: 0,
                                    depenses: [], frais: [], virements: virements, maintenant: date(10, 28), calendrier: cal)
        #expect(t.soldeAujourdhui == -200_00)
    }

    @Test func fraisProRembourse() {
        let pro = Depense(montantCentimes: 60_00, posteID: Poste.pro, date: date(10, 20))
        let courses = Depense(montantCentimes: 40_00, posteID: "courses", date: date(10, 20))
        pro.rembourseLe = date(10, 27)
        let mois = Periodes.mois(contenant: date(10, 20), calendrier: cal)
        #expect(Cumuls.parPoste([pro, courses], mois: mois) == ["courses": 40_00])
        // Payé avant le solde saisi, remboursé après : le montant revient.
        let t = Tresorerie.calculer(solde: 100_00, datePoint: date(10, 25), jourPaie: 6, salaire: 0, marge: 0,
                                    depenses: [pro, courses], frais: [], maintenant: date(10, 28), calendrier: cal)
        #expect(t.soldeAujourdhui == 160_00)
    }

    @Test func salaireRecuAvantLaDateAuPlusTard() {
        let t = Tresorerie.calculer(solde: -300_00, datePoint: date(10, 25), jourPaie: 6, salaire: 2_000_00, marge: 100_00,
                                    paieRecue: date(11, 2, 9), depenses: [], frais: [], maintenant: date(11, 3), calendrier: cal)
        #expect(t.soldeAujourdhui == 1_700_00)
        #expect(t.prochainePaie == cal.startOfDay(for: date(12, 6)))
        #expect(t.aDepenserAvantPaie == 1_600_00)
        // Le 7, la paie du 6 est passée : pas comptée deux fois.
        let plusTard = Tresorerie.calculer(solde: -300_00, datePoint: date(10, 25), jourPaie: 6, salaire: 2_000_00, marge: 0,
                                           paieRecue: date(11, 2, 9), depenses: [], frais: [], maintenant: date(11, 7), calendrier: cal)
        #expect(plusTard.soldeAujourdhui == 1_700_00)
    }
}

@MainActor
struct TresorerieSyncTests {
    @Test func reglagesLesPlusRecentsGagnent() throws {
        let avant = (PactoleReglages.tresorerie, PactoleReglages.tresorerieModifie)
        defer { PactoleReglages.tresorerie = avant.0; PactoleReglages.tresorerieModifie = avant.1 }
        PactoleReglages.tresorerieModifie = Date(timeIntervalSince1970: 1_000)
        let distant = ReglagesTresorerie(soldeCentimes: -300_00, soldeDate: 2_000, jourPaie: 6,
                                         salaireAttenduCentimes: 0, margeCentimes: 50_00, paieRecue: 0)
        var fichier = PactoleBackup(plafondHebdoCentimes: PactoleReglages.plafondHebdoCentimes, postes: [], depenses: [],
                                  plafondHebdoModifie: .distantPast, tresorerie: distant,
                                  tresorerieModifie: Date(timeIntervalSince1970: 2_000))
        fichier = try PactoleBackup.decode(fichier.encoded())
        let container = try ModelContainer(for: Schema(PactoleSchema.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        try PactoleSync.merge([fichier], into: container.mainContext)
        #expect(PactoleReglages.tresorerie == distant)
        // Plus ancien que le local : ignoré.
        fichier.tresorerie?.margeCentimes = 10_00
        fichier.tresorerieModifie = Date(timeIntervalSince1970: 1_500)
        try PactoleSync.merge([fichier], into: container.mainContext)
        #expect(PactoleReglages.tresorerie.margeCentimes == 50_00)
        // Virements : sauvegardés et repris.
        let contexte = container.mainContext
        contexte.insert(Virement(date: Date(timeIntervalSince1970: 3_000), montantCentimes: 50_00, note: "Livret"))
        try contexte.save()
        let copie = try PactoleBackup.decode(PactoleBackup.make(from: contexte).encoded())
        let autre = try ModelContainer(for: Schema(PactoleSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        try PactoleSync.merge([copie], into: autre.mainContext)
        let repris = try autre.mainContext.fetch(FetchDescriptor<Virement>())
        #expect(repris.map(\.montantCentimes) == [50_00] && repris.first?.note == "Livret")
    }
}

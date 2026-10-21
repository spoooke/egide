import Foundation
import SwiftData
import Testing
@testable import PactoleKit

// Relevé du mois (phase 7) : lignes fictives, positionnées comme sur un relevé Société Générale
// (dates à gauche, libellé au milieu, montant sous « Débit » ou « Crédit »).

/// Midi, le `j` du mois `m` 2026.
private func le(_ j: Int, _ m: Int = 10, _ a: Int = 2026) -> Date {
    Calendar.francais.date(from: DateComponents(year: a, month: m, day: j, hour: 12))!
}

private let colonnes = PageReleve.Colonnes(debit: 443, credit: 526)

/// Morceaux (abscisse de début, texte) : la fin est estimée à 5 points par caractère.
private func ligne(_ morceaux: (Double, String)...) -> LigneReleve {
    LigneReleve(morceaux: morceaux.map { MorceauReleve(debut: $0.0, fin: $0.0 + Double($0.1.count) * 5, texte: $0.1) })
}

/// Première ligne d'une opération : date d'opération, date de valeur, libellé, montant au débit ou au crédit.
private func operation(_ date: String, _ libelle: String, debit: String? = nil, credit: String? = nil) -> LigneReleve {
    var morceaux = [(31.0, date), (77.0, date), (124.0, libelle)]
    if let debit { morceaux.append((450, debit)) }
    if let credit { morceaux.append((530, credit)) }
    return LigneReleve(morceaux: morceaux.map { MorceauReleve(debut: $0.0, fin: $0.0 + Double($0.1.count) * 5, texte: $0.1) })
}

private let entete = ligne((40, "Date Valeur Nature de l'opération Débit Crédit"))

/// Relevé fictif d'octobre 2026 sur deux pages. Débits : 13 + 13,49 + 40 + 25,20 + 1.050 = 1.141,69 ; crédits : 1.800 + 12,50.
private func pagesFictives(totalDebits: String = "1.141,69", totalCredits: String = "1.812,50") -> [PageReleve] {
    [
        PageReleve(lignes: [
            ligne((423, "RELEVÉ DE COMPTE")),
            ligne((434, "du 01/10/2026 au 31/10/2026")),
            entete,
            ligne((262, "SOLDE PRÉCÉDENT AU 30/09/2026"), (528, "2.000,00")),
            operation("06/10/2026", "CARTE X1234 05/10 E.LECLERC ORLEANS", debit: "13,00"),
            operation("07/10/2026", "PRELEVEMENT EUROPEEN 1234567890", debit: "13,49"),
            ligne((124, "DE: NETFLIX INTERNATIONAL")),
            ligne((124, "ID: FR00ZZZ000000")),
            ligne((124, "REF: 0000000000")),
            operation("08/10/2026", "CARTE X1234 RETRAIT DAB SG 08/10 12H00", debit: "40,00"),
            ligne((124, "AGENCE FICTIVE 00000000")),
            ligne((579, "n° fictif vertical")),
            ligne((529, "suite >>>")),
            ligne((28, "Pied de page fictif")),
        ], colonnes: colonnes),
        PageReleve(lignes: [
            ligne((423, "RELEVÉ DE COMPTE")),
            entete,
            operation("09/10/2026", "CARTE X1234 08/10 PAYPAL *BOUTIQUE", debit: "25,20"),
            ligne((124, "COMMERCE ELECTRONIQUE")),
            ligne((262, "*** SOLDE AU 09/10/2026 - 1.908,31 ***")),
            operation("10/10/2026", "VIR RECU 0000000000000", credit: "1.800,00"),
            ligne((124, "DE: EMPLOYEUR FICTIF")),
            ligne((124, "MOTIF: SALAIRE OCTOBRE")),
            operation("12/10/2026", "CARTE X1234 REMBT 11/10 BOUTIQUE", credit: "12,50"),
            operation("15/10/2026", "ECHEANCE PRET N°000000000000", debit: "1.050,00"),
            ligne((124, "CAPITAL AMORTI : 900,00")),
            ligne((290, "TOTAUX DES MOUVEMENTS"), (445, totalDebits), (528, totalCredits)),
            ligne((271, "NOUVEAU SOLDE AU 31/10/2026"), (521, "+ 2.670,81")),
        ], colonnes: colonnes),
    ]
}

struct ReleveLectureTests {
    @Test func operationsDuReleve() throws {
        let releve = try Releve.analyser(pagesFictives())
        #expect(releve.debut == le(1))
        #expect(releve.fin == le(31))
        #expect(releve.operations.count == 7)
        #expect(releve.totalDebits == 1_141_69)
        #expect(releve.totalCredits == 1_812_50)

        let carte = releve.operations[0]
        #expect(carte.genre == .carte)
        #expect(carte.centimes == 13_00 && !carte.credit)
        #expect(carte.dateOperation == le(6))
        #expect(carte.dateAchat() == le(5))
        #expect(carte.commercant == "E.LECLERC ORLEANS")

        // Libellé sur plusieurs lignes ; le tiers est celui de « DE: ».
        let prelevement = releve.operations[1]
        #expect(prelevement.genre == .prelevement)
        #expect(prelevement.lignes.count == 4)
        #expect(prelevement.commercant == "NETFLIX INTERNATIONAL")

        // Le texte vertical de la marge et le pied de page ne rejoignent pas le libellé.
        let retrait = releve.operations[2]
        #expect(retrait.genre == .retrait)
        #expect(retrait.lignes == ["CARTE X1234 RETRAIT DAB SG 08/10 12H00", "AGENCE FICTIVE 00000000"])

        let paypal = releve.operations[3]
        #expect(paypal.commercant == "BOUTIQUE")
        #expect(paypal.lignes.count == 2) // « *** SOLDE AU … *** » ne fait pas partie du libellé

        let salaire = releve.operations[4]
        #expect(salaire.credit && salaire.centimes == 1_800_00)
        #expect(salaire.genre == .virement)
        #expect(salaire.commercant == "EMPLOYEUR FICTIF")

        let remboursement = releve.operations[5]
        #expect(remboursement.credit && remboursement.dateAchat() == le(11))

        // Montant dans le libellé (« CAPITAL AMORTI : 900,00 ») : pas un montant de l'opération.
        #expect(releve.operations[6].centimes == 1_050_00)
        #expect(releve.operations[6].lignes.count == 2)
    }

    @Test func totauxDifferentsRefuses() {
        #expect(throws: Releve.Erreur.totauxDifferents(debitsLus: 1_141_69, debitsImprimes: 1_141_70,
                                                         creditsLus: 1_812_50, creditsImprimes: 1_812_50)) {
            try Releve.analyser(pagesFictives(totalDebits: "1.141,70"))
        }
    }

    @Test func totauxIntrouvables() {
        var pages = pagesFictives()
        pages[1].lignes.removeAll { $0.texte.contains("TOTAUX") }
        #expect(throws: Releve.Erreur.totauxIntrouvables) { try Releve.analyser(pages) }
    }

    @Test func pasUnReleve() {
        #expect(throws: Releve.Erreur.pasUnReleve) {
            try Releve.analyser([PageReleve(lignes: [ligne((40, "Facture fictive")), ligne((40, "Total 12,00 €"))], colonnes: nil)])
        }
    }

    @Test func montants() {
        #expect(Releve.centimes("1.234,56") == 1_234_56)
        #expect(Releve.centimes("9,99") == 9_99)
        #expect(Releve.centimes("+ 12.345,00") == 1_234_500)
        #expect(Releve.centimes("12,5") == nil)
        #expect(Releve.centimes("SALAIRE") == nil)
    }

    @Test func achatDeLAnneePrecedente() {
        let op = OperationReleve(dateOperation: le(2, 1, 2027), dateValeur: le(2, 1, 2027),
                                 lignes: ["CARTE X1234 31/12 BOULANGERIE"], centimes: 3_20, credit: false)
        #expect(op.dateAchat() == le(31, 12, 2026))
    }

    @Test func identifiantsStablesEtDistincts() throws {
        var pages = pagesFictives(totalDebits: "1.154,69")
        // Deux achats identiques le même jour : même libellé, rang différent.
        pages[0].lignes.insert(operation("06/10/2026", "CARTE X1234 05/10 E.LECLERC ORLEANS", debit: "13,00"), at: 5)
        let releve = try Releve.analyser(pages)
        #expect(releve.operations[0].id != releve.operations[1].id)
        #expect(releve.operations[1].rang == 1)
        #expect(try Releve.analyser(pages).operations.map(\.id) == releve.operations.map(\.id))
        // Rien de lisible du libellé dans l'identifiant.
        #expect(!releve.operations[0].id.localizedCaseInsensitiveContains("leclerc"))
    }

    @Test func intermediaires() {
        #expect(OperationReleve.sansIntermediaire("PAYPAL *STEAMGAMES") == "STEAMGAMES")
        #expect(OperationReleve.sansIntermediaire("SUMUP *CAFE DU PORT") == "CAFE DU PORT")
        #expect(OperationReleve.sansIntermediaire("AMZN MKTP*FR") == "AMZN MKTP FR")
    }
}

@MainActor
struct RapprochementTests {
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try ModelContainer(for: Schema(PactoleSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = container.mainContext
        PactoleDatabase.ajouterPostesDeDepart(dans: context)
        Rapprochement.tiersSalaire = []
    }

    private func depense(_ centimes: Int, _ date: Date, _ commercant: String = "", source: SourceDepense = .applePay) -> Depense {
        let d = Depense(montantCentimes: centimes, posteID: "courses", date: date, source: source)
        d.commercant = commercant
        context.insert(d)
        return d
    }

    private func issue(_ plan: Rapprochement.Plan, _ index: Int) -> Rapprochement.Issue { plan.lignes[index].issue }

    @Test func importDuReleve() throws {
        let applePay = depense(13_00, le(5, 10).addingTimeInterval(3600), "E.Leclerc") // achat Apple Pay du 5
        let netflix = FraisFixe(nom: "Netflix", montantCentimes: 13_49, jour: 7, categorie: .abonnement)
        let pret = FraisFixe(nom: "Crédit maison", montantCentimes: 1_050_00, jour: 15, categorie: .credit)
        context.insert(netflix)
        context.insert(pret)
        try context.save()

        let releve = try Releve.analyser(pagesFictives())
        let plan = try Rapprochement.preparer(releve, dans: context)
        #expect(issue(plan, 0) == .liee(applePay))
        #expect(issue(plan, 1) == .fraisFixe(nom: "Netflix"))       // nom retrouvé dans le libellé
        #expect(issue(plan, 2) == .retrait)
        #expect(issue(plan, 3) == .nouvelle(posteID: Poste.divers, aVerifier: true))
        #expect(issue(plan, 6) == .fraisFixe(nom: "Crédit maison")) // même montant, même jour
        #expect(plan.revenus.count == 2)
        #expect(plan.revenus[0].salaire && plan.revenus[0].retenu && plan.revenus[0].libelle == "Salaire")
        #expect(plan.revenus[0].mois == "2026-10")
        #expect(!plan.revenus[1].retenu) // remboursement : à confirmer

        let bilan = try Rapprochement.appliquer(plan, dans: context)
        #expect(bilan == .init(liees: 1, nouvelles: 1, aVerifier: 0, ignorees: 3, revenus: 1))
        #expect(applePay.banqueID == releve.operations[0].id)
        let banque = try #require(try context.fetch(FetchDescriptor<Depense>()).first { $0.source == .banque })
        #expect(banque.montantCentimes == 25_20 && banque.date == le(8) && banque.commercant == "BOUTIQUE")
        let revenus = try context.fetch(FetchDescriptor<Revenu>())
        #expect(revenus.map(\.montantCentimes) == [1_800_00])
        #expect(Rapprochement.tiersSalaire == ["employeur fictif"])

        // Même relevé une deuxième fois : refusé, rien n'est importé deux fois.
        #expect(throws: Rapprochement.Erreur.self) { try Rapprochement.preparer(releve, dans: context) }
    }

    @Test func depenseSupprimeeNeRevientPas() throws {
        let releve = try Releve.analyser(pagesFictives())
        try Rapprochement.appliquer(try Rapprochement.preparer(releve, dans: context), dans: context)
        for d in try context.fetch(FetchDescriptor<Depense>()) { Suppressions.supprimer(d, dans: context) }
        try context.save()
        // Autre relevé (période différente) qui reprend les mêmes opérations : toutes déjà vues.
        var autre = releve
        autre.fin = le(30)
        let plan = try Rapprochement.preparer(autre, dans: context)
        #expect(plan.lignes.allSatisfy { $0.issue == .dejaVue })
        #expect(plan.revenus.isEmpty)
    }

    @Test func commercantPourDepartager() throws {
        _ = depense(13_00, le(5), "Boulangerie")
        let leclerc = depense(13_00, le(6), "E.Leclerc")
        let plan = try Rapprochement.preparer(try Releve.analyser(pagesFictives()), dans: context)
        #expect(issue(plan, 0) == .liee(leclerc))
    }

    @Test func achatsIdentiquesPartages() throws {
        let a = depense(13_00, le(5), "Tabac"), b = depense(13_00, le(5), "Tabac")
        var pages = pagesFictives(totalDebits: "1.154,69")
        pages[0].lignes.insert(operation("06/10/2026", "CARTE X1234 05/10 E.LECLERC ORLEANS", debit: "13,00"), at: 5)
        let plan = try Rapprochement.preparer(try Releve.analyser(pages), dans: context)
        let liees = [issue(plan, 0), issue(plan, 1)].compactMap { i -> Depense? in
            if case .liee(let d) = i { d } else { nil }
        }
        #expect(Set(liees.map(\.persistentModelID)) == [a.persistentModelID, b.persistentModelID])
    }

    @Test func plusieursCandidatesAVerifier() throws {
        _ = depense(13_00, le(4), "Tabac")
        let proche = depense(13_00, le(5), "Tabac")
        let plan = try Rapprochement.preparer(try Releve.analyser(pagesFictives()), dans: context)
        #expect(issue(plan, 0) == .aVerifier(proche, candidates: 2))
        try Rapprochement.appliquer(plan, dans: context)
        #expect(proche.aVerifier && !proche.banqueID.isEmpty)
    }

    @Test func horsFenetreNouvelleDepense() throws {
        _ = depense(13_00, le(1), "E.Leclerc") // 4 jours avant l'achat
        let plan = try Rapprochement.preparer(try Releve.analyser(pagesFictives()), dans: context)
        #expect(issue(plan, 0) == .nouvelle(posteID: "tabac", aVerifier: false)) // Leclerc de 13 € : règle du tabac
    }

    @Test func fraisAnnuelPasIgnore() throws {
        let annuel = FraisFixe(nom: "Netflix", montantCentimes: 13_49, jour: 7, categorie: .abonnement)
        annuel.moisAnnuel = 10
        context.insert(annuel)
        let plan = try Rapprochement.preparer(try Releve.analyser(pagesFictives()), dans: context)
        // Paiement d'un frais annuel : dépense du jour, en Imprévu (hors plafond de la semaine).
        #expect(issue(plan, 1) == .nouvelle(posteID: Poste.imprevu, aVerifier: false))
    }

    private func carte(_ jour: Int, _ commercant: String, _ centimes: Int) -> OperationReleve {
        OperationReleve(dateOperation: le(jour + 1), dateValeur: le(jour + 1),
                        lignes: [String(format: "CARTE X1234 %02d/10 %@", jour, commercant), "COMMERCE ELECTRONIQUE"],
                        centimes: centimes, credit: false)
    }

    private func releve(_ operations: [OperationReleve]) -> Releve {
        Releve(debut: le(1), fin: le(31), operations: operations,
               totalDebits: operations.reduce(0) { $0 + $1.centimes }, totalCredits: 0)
    }

    private func frais(_ nom: String, _ centimes: Int, jour: Int, motif: String = "") -> FraisFixe {
        let f = FraisFixe(nom: nom, montantCentimes: centimes, jour: jour, categorie: .abonnement)
        f.motifBanque = motif
        context.insert(f)
        return f
    }

    /// Paiement par carte d'un abonnement : reconnu par le nom du frais (bug du 8 octobre : jamais reconnu).
    @Test func abonnementParCarte() throws {
        _ = frais("Spotify", 12_14, jour: 4)
        _ = frais("Crunchyroll", 6_99, jour: 2)
        let plan = try Rapprochement.preparer(releve([carte(4, "PAYPAL *SPOTIFY*P467", 12_14),
                                                      carte(2, "PAYPAL *CRUNCHYROLL", 6_99)]), dans: context)
        #expect(issue(plan, 0) == .fraisFixe(nom: "Spotify"))
        #expect(issue(plan, 1) == .fraisFixe(nom: "Crunchyroll"))
    }

    /// « Netflix (2 abonnements) » : deux prélèvements dont la somme fait le frais ; prix qui bouge un peu.
    @Test func fraisEnPlusieursOperations() throws {
        _ = frais("Netflix (2 abonnements)", 29_98, jour: 11)
        _ = frais("Patreon", 6_00, jour: 21)
        let plan = try Rapprochement.preparer(releve([carte(11, "PAYPAL *NETFLIX", 21_99), carte(11, "PAYPAL *NETFLIX", 7_99),
                                                      carte(20, "PATREON INC", 5_61)]), dans: context)
        #expect(plan.lignes.map(\.issue) == [.fraisFixe(nom: "Netflix (2 abonnements)"), .fraisFixe(nom: "Netflix (2 abonnements)"),
                                             .fraisFixe(nom: "Patreon")])
    }

    /// Nom tronqué par la banque, deux prêts pour un frais.
    @Test func nomTronque() throws {
        _ = frais("Prêts Franfinance Expresso (2)", 304_43, jour: 21)
        _ = frais("GAN assurances", 108_38, jour: 7)
        let pret = { (centimes: Int) in
            OperationReleve(dateOperation: le(21), dateValeur: le(21), lignes: ["PRELEVEMENT EUROPEEN 0000000000",
                            "DE: PRET SOGEFINANC.EXPRESSO-FRANFINANC"], centimes: centimes, credit: false)
        }
        let assurance = OperationReleve(dateOperation: le(20), dateValeur: le(20),
                                        lignes: ["PRELEVEMENT EUROPEEN 0000000000", "DE: AXA ASSURANCES"], centimes: 40_00, credit: false)
        let plan = try Rapprochement.preparer(releve([pret(225_06), pret(79_37), assurance]), dans: context)
        #expect(issue(plan, 0) == .fraisFixe(nom: "Prêts Franfinance Expresso (2)"))
        #expect(issue(plan, 1) == .fraisFixe(nom: "Prêts Franfinance Expresso (2)"))
        guard case .nouvelle = issue(plan, 2) else { Issue.record("« assurances » seul ne suffit pas"); return }
    }

    /// Libellé appris (« itunesappst appl ») partagé par plusieurs frais : chacun prend l'opération de son montant.
    @Test func libelleApprisPartage() throws {
        _ = frais("Lightroom", 12_99, jour: 8, motif: "itunesappst appl")
        _ = frais("iCloud+", 2_99, jour: 8, motif: "itunesappst appl")
        let plan = try Rapprochement.preparer(releve([carte(8, "ITUNESAPPST APPL", 12_99), carte(8, "ITUNESAPPST APPL", 2_99),
                                                      carte(8, "ITUNESAPPST APPL", 16_99)]), dans: context)
        #expect(issue(plan, 0) == .fraisFixe(nom: "Lightroom"))
        #expect(issue(plan, 1) == .fraisFixe(nom: "iCloud+"))
        guard case .nouvelle = issue(plan, 2) else { Issue.record("achat de l'App Store : dépense"); return }
    }

    /// Relevés anciens : Apple sous un autre libellé, YouTube facturé par Google à l'ancien prix, nom collé.
    @Test func aliasEtAncienPrix() throws {
        _ = frais("Lightroom", 12_99, jour: 8, motif: "itunesappst appl")
        _ = frais("iCloud+", 2_99, jour: 8, motif: "itunesappst appl")
        _ = frais("YouTube Premium", 16_99, jour: 7, motif: "itunesappst appl")
        _ = frais("EDF Systèmes énergétiques", 98_00, jour: 21)
        let edf = OperationReleve(dateOperation: le(6), dateValeur: le(6),
                                  lignes: ["PRELEVEMENT EUROPEEN 0000000000", "DE: EDF SYSTEMES ENERGETIQU"], centimes: 333_51, credit: false)
        let plan = try Rapprochement.preparer(releve([carte(8, "APPLE.COM/BILL", 2_99), carte(7, "APPLE.COM/BILL", 12_99),
                                                      carte(5, "Google YouTubePremium", 12_99), edf]), dans: context)
        #expect(plan.lignes.map(\.issue) == [.fraisFixe(nom: "iCloud+"), .fraisFixe(nom: "Lightroom"),
                                             .fraisFixe(nom: "YouTube Premium"), .nouvelle(posteID: Poste.divers, aVerifier: true)])
    }

    @Test func rattacherAUnFrais() throws {
        try Rapprochement.appliquer(try Rapprochement.preparer(releve([carte(8, "ITUNESAPPST APPL", 12_99),
                                                                       carte(20, "ASACARDOROLE", 155_42)]), dans: context),
                                    dans: context)
        let depenses = try context.fetch(FetchDescriptor<Depense>())
        let itunes = try #require(depenses.first { $0.montantCentimes == 12_99 })
        let eau = try #require(depenses.first { $0.montantCentimes == 155_42 })
        let lightroom = frais("Lightroom", 12_99, jour: 8)
        try Rapprochement.rattacher(itunes, a: lightroom, dans: context)
        #expect(lightroom.motifBanque == "itunesappst appl")
        #expect(try context.fetchCount(FetchDescriptor<Depense>()) == 1) // déjà comptée dans les frais fixes

        let annuel = try Rapprochement.nouveauFrais(depuis: eau, annuel: true, dans: context)
        #expect(annuel.moisAnnuel == 10 && annuel.motifBanque == "asacardorole" && annuel.nom == "Asacardorole")
        #expect(eau.posteID == Poste.imprevu && !eau.aVerifier)
    }

    @Test func annulerLImport() throws {
        let applePay = depense(13_00, le(5), "E.Leclerc")
        let releve = try Releve.analyser(pagesFictives())
        try Rapprochement.appliquer(try Rapprochement.preparer(releve, dans: context), dans: context)
        #expect(!applePay.banqueID.isEmpty)
        let ajoute = try #require(try context.fetch(FetchDescriptor<ReleveAjoute>()).first)
        try Rapprochement.annuler(ajoute, dans: context)
        #expect(applePay.banqueID.isEmpty)
        #expect(try context.fetch(FetchDescriptor<Depense>()).map(\.syncID) == [applePay.syncID])
        #expect(try context.fetchCount(FetchDescriptor<Revenu>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<OperationVue>()) == 0)
        // Le relevé peut être ajouté de nouveau.
        #expect(try Rapprochement.preparer(releve, dans: context).lignes.first?.issue == .liee(applePay))
    }

    @Test func salaireDejaSaisi() throws {
        context.insert(Revenu(mois: "2026-10", libelle: "Salaire", montantCentimes: 1_800_00))
        let plan = try Rapprochement.preparer(try Releve.analyser(pagesFictives()), dans: context)
        #expect(plan.revenus[0].dejaSaisi && !plan.revenus[0].retenu)
    }

    /// Salaire sans le mot « salaire » dans le virement : appris d'un revenu déjà saisi (même mois, même montant).
    @Test func salaireAppris() throws {
        var pages = pagesFictives()
        pages[1].lignes[7] = ligne((124, "MOTIF: VIREMENT DU MOIS"))
        context.insert(Revenu(mois: "2026-10", libelle: "Salaire Fictif", montantCentimes: 1_800_00))
        let plan = try Rapprochement.preparer(try Releve.analyser(pages), dans: context)
        #expect(plan.revenus[0].salaire && plan.revenus[0].dejaSaisi && !plan.revenus[0].retenu)
        #expect(Rapprochement.tiersSalaire == ["employeur fictif"])

        // Mois suivant, autre montant (astreintes) : reconnu, coché, même libellé.
        let novembre = OperationReleve(dateOperation: le(3, 11), dateValeur: le(3, 11),
                                       lignes: ["VIR RECU 0000000000000", "DE: EMPLOYEUR FICTIF", "MOTIF: VIREMENT DU MOIS"],
                                       centimes: 1_843_17, credit: true)
        let suivant = try Rapprochement.preparer(Releve(debut: le(1, 11), fin: le(30, 11), operations: [novembre],
                                                        totalDebits: 0, totalCredits: 1_843_17), dans: context)
        #expect(suivant.revenus[0].salaire && suivant.revenus[0].retenu && suivant.revenus[0].libelle == "Salaire Fictif")
        #expect(suivant.revenus[0].mois == "2026-11")
    }

    /// Sens inverse : le paiement Apple Pay arrive après l'import du relevé.
    @Test func applePayApresLeReleve() throws {
        try Rapprochement.appliquer(try Rapprochement.preparer(try Releve.analyser(pagesFictives()), dans: context), dans: context)
        let avant = try context.fetchCount(FetchDescriptor<Depense>())
        let resultat = try Paiements.ajouter(commercant: "Boutique en ligne", centimes: 25_20, carte: "CB Visa", date: le(8), dans: context)
        guard case .rapprochee = resultat else { Issue.record("attendu : rapprochée, obtenu \(resultat)"); return }
        #expect(try context.fetchCount(FetchDescriptor<Depense>()) == avant)
        let banque = try #require(try context.fetch(FetchDescriptor<Depense>()).first { $0.source == .banque && $0.montantCentimes == 25_20 })
        #expect(banque.commercant == "Boutique en ligne" && banque.carte == "CB Visa")
        // Autre montant : nouvelle dépense.
        #expect(try Paiements.ajouter(commercant: "Boutique en ligne", centimes: 25_21, carte: "", date: le(8), dans: context)
                == .ajoutee(posteID: Poste.divers, aVerifier: true))
    }

    @Test func depenseDuReleveFenetre() {
        let banque = depense(50_00, le(10), "PRLV", source: .banque)
        banque.banqueID = "x"
        #expect(Rapprochement.depenseDuReleve(centimes: 50_00, date: le(7), parmi: [banque]) === banque)
        #expect(Rapprochement.depenseDuReleve(centimes: 50_00, date: le(11), parmi: [banque]) === banque)
        #expect(Rapprochement.depenseDuReleve(centimes: 50_00, date: le(5), parmi: [banque]) == nil)
        #expect(Rapprochement.depenseDuReleve(centimes: 50_01, date: le(10), parmi: [banque]) == nil)
    }

    /// Le rapprochement voyage avec la synchro ; un appareil d'avant la phase 7 ne l'efface pas.
    @Test func banqueIDSynchronise() throws {
        let d = depense(13_00, le(5), "E.Leclerc")
        d.banqueID = "empreinte"
        try context.save()
        var fichier = try PactoleBackup.make(from: context)
        #expect(fichier.depenses.first?.banqueID == "empreinte")

        let autre = try ModelContainer(for: Schema(PactoleSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        try PactoleBackup.decode(fichier.encoded()).restore(into: autre.mainContext)
        let copie = try #require(try autre.mainContext.fetch(FetchDescriptor<Depense>()).first)
        #expect(copie.banqueID == "empreinte")

        fichier.depenses[0].banqueID = nil
        fichier.depenses[0].modifiedAt = .now.addingTimeInterval(60)
        try PactoleBackup.decode(fichier.encoded()).restore(into: autre.mainContext)
        #expect(copie.banqueID == "empreinte")
    }

    @Test func especes() throws {
        let d = depense(8_00, le(5), source: .especes)
        #expect(d.source.libelle == "Espèces")
        #expect(SourceDepense(rawValue: "especes") == .especes)
    }
}

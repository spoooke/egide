import Foundation
import SwiftData
import Testing
@testable import PactoleKit

struct PactoleKitTests {
    @Test func routes() {
        #expect(PactoleRoute(path: []) == .week)
        #expect(PactoleRoute(path: ["add"]) == .add)
    }
}

struct BudgetTests {
    /// Les espaces insécables du format français, remplacés par des espaces simples.
    private func texte(_ montant: Decimal) -> String {
        Budget.euros(montant).replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    @Test func montantsAffichesALaFrancaise() {
        #expect(texte(135) == "135 €")
        #expect(texte(Decimal(string: "12.5")!) == "12,50 €")
        #expect(texte(1250) == "1 250 €")
    }
}

struct MontantTests {
    @Test func saisie() {
        #expect(Montant.centimes(depuis: "12,50") == 1250)
        #expect(Montant.centimes(depuis: "12.5") == 1250)
        #expect(Montant.centimes(depuis: "7") == 700)
        #expect(Montant.centimes(depuis: " 1 250,99 € ") == 125_099)
        #expect(Montant.centimes(depuis: "0,01") == 1)
    }

    @Test func saisieInvalide() {
        for texte in ["", "0", "abc", "12,5,0", "-3", "1,234"] {
            #expect(Montant.centimes(depuis: texte) == nil, "\(texte)")
        }
    }
}

/// 5 octobre 2026 : un lundi.
private func jour(_ decalage: Int, heure: Int = 12) -> Date {
    let lundi = Calendar.francais.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: heure))!
    return Calendar.francais.date(byAdding: .day, value: decalage, to: lundi)!
}

struct SemaineTests {
    @Test func joursRestantsJusquaDimanche() {
        #expect(Semaine(plafond: 135, depense: 0, aujourdhui: jour(0)).joursRestants == 7)
        #expect(Semaine(plafond: 135, depense: 0, aujourdhui: jour(3)).joursRestants == 4)
        #expect(Semaine(plafond: 135, depense: 0, aujourdhui: jour(6)).joursRestants == 1)
    }

    @Test func resteEtParJour() {
        let semaine = Semaine(plafond: 135, depense: 35, aujourdhui: jour(3)) // jeudi
        #expect(semaine.reste == 100)
        #expect(semaine.parJour == 25)
        // 135 / 7 = 19,2857… arrondi au centime inférieur.
        #expect(Semaine(plafond: 135, depense: 0, aujourdhui: jour(0)).parJour == Decimal(string: "19.28")!)
    }

    @Test func etats() {
        #expect(Semaine(plafond: 135, depense: 0, aujourdhui: jour(0)).etat == .large)
        #expect(Semaine(plafond: 100, depense: 75, aujourdhui: jour(0)).etat == .large) // 25 % pile
        #expect(Semaine(plafond: 100, depense: 76, aujourdhui: jour(0)).etat == .serre)
        #expect(Semaine(plafond: 100, depense: 101, aujourdhui: jour(0)).etat == .depasse)
    }

    @Test func depassement() {
        let semaine = Semaine(plafond: 135, depense: 150, aujourdhui: jour(2))
        #expect(semaine.reste == -15)
        #expect(semaine.parJour == 0)
        #expect(semaine.proportionRestante == 0)
    }
}

struct PeriodesTests {
    @Test func semaineDuLundiAuDimanche() {
        let semaine = Periodes.semaine(contenant: jour(3))
        #expect(semaine.start == Calendar.francais.startOfDay(for: jour(0)))
        #expect(semaine.inclut(jour(6, heure: 23)))
        #expect(!semaine.inclut(jour(7, heure: 0)))
        #expect(!semaine.inclut(jour(-1, heure: 23)))
    }

    @Test func mois() {
        let octobre = Periodes.mois(contenant: jour(0))
        #expect(octobre.inclut(jour(-4))) // 1er octobre
        #expect(!octobre.inclut(jour(-5))) // 30 septembre
    }

    @Test func etatPlafond() {
        #expect(EtatPlafond(totalCentimes: 100, plafondCentimes: nil) == .sansPlafond)
        #expect(EtatPlafond(totalCentimes: 79_00, plafondCentimes: 100_00) == .large)
        #expect(EtatPlafond(totalCentimes: 80_00, plafondCentimes: 100_00) == .proche)
        #expect(EtatPlafond(totalCentimes: 100_00, plafondCentimes: 100_00) == .proche)
        #expect(EtatPlafond(totalCentimes: 100_01, plafondCentimes: 100_00) == .depasse)
    }
}

@MainActor
struct CumulsTests {
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try ModelContainer(for: Schema(PactoleSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = container.mainContext
        PactoleDatabase.ajouterPostesDeDepart(dans: context)
    }

    private func depense(_ euros: Int, _ poste: String, _ date: Date) -> Depense {
        let d = Depense(montantCentimes: euros * 100, posteID: poste, date: date)
        context.insert(d)
        return d
    }

    @Test func postesDeDepartUneSeuleFois() throws {
        PactoleDatabase.ajouterPostesDeDepart(dans: context)
        let postes = try context.fetch(FetchDescriptor<Poste>())
        #expect(postes.count == Poste.depart().count)
        #expect(postes.first { $0.syncID == Poste.imprevu }?.horsPlafondHebdo == true)
        #expect(postes.first { $0.syncID == "courses" }?.plafondMensuelCentimes == 320_00)
    }

    @Test func imprevuHorsPlafondHebdo() {
        let liste = [depense(30, "courses", jour(1)), depense(200, Poste.imprevu, jour(2)), depense(10, "tabac", jour(-1))]
        let total = Cumuls.totalSemaine(liste, postesHorsPlafond: [Poste.imprevu], semaine: Periodes.semaine(contenant: jour(0)))
        #expect(total == 30_00) // sans l'imprévu, sans la semaine précédente
    }

    @Test func parPosteSurLeMois() {
        let liste = [depense(30, "courses", jour(1)), depense(20, "courses", jour(-4)), depense(5, "courses", jour(-5)),
                     depense(200, Poste.imprevu, jour(2))]
        let totaux = Cumuls.parPoste(liste, mois: Periodes.mois(contenant: jour(0)))
        #expect(totaux["courses"] == 50_00) // le 30 septembre n'est pas en octobre
        #expect(totaux[Poste.imprevu] == 200_00)
    }

    @Test func parSemaine() {
        let liste = [depense(1, "courses", jour(1)), depense(2, "courses", jour(-1)), depense(3, "courses", jour(-6))]
        let groupes = Cumuls.parSemaine(liste)
        #expect(groupes.count == 2)
        #expect(groupes[0].depenses.map(\.montantCentimes) == [100])
        #expect(groupes[1].depenses.map(\.montantCentimes) == [200, 300])
    }

    @Test func sauvegardeEtRestauration() throws {
        _ = depense(12, "courses", jour(1))
        try context.save()
        let fichier = try PactoleBackup.make(from: context).encoded()

        let autre = try ModelContainer(for: Schema(PactoleSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let restauration = try PactoleBackup.decode(fichier)
        let attendu = Poste.depart().count + 1 + Regle.depart().count // postes, dépense, règles de classement
        #expect(try restauration.restore(into: autre.mainContext) == attendu)
        #expect(try autre.mainContext.fetch(FetchDescriptor<Depense>()).first?.montantCentimes == 12_00)
        // Une deuxième restauration ne change rien.
        #expect(try restauration.restore(into: autre.mainContext) == 0)
    }

    @Test func sauvegardeCompleteEtNomDeFichier() throws {
        let frais = FraisFixe(nom: "Abonnement test", montantCentimes: 9_99, jour: 3, categorie: .autre)
        frais.motifBanque = "abonnement test"
        context.insert(frais)
        context.insert(Revenu(mois: "2026-10", libelle: "Salaire", montantCentimes: 1_000_00))
        let d = depense(7, "tabac", jour(2))
        d.banqueID = "banque-1"
        try context.save()
        let fichier = try PactoleBackup.decode(try PactoleBackup.make(from: context).encoded())
        #expect(fichier.fraisFixes?.first?.motifBanque == "abonnement test")
        #expect(fichier.revenus?.first?.montantCentimes == 1_000_00)
        #expect(fichier.depenses.first?.banqueID == "banque-1")
        #expect(fichier.plafondHebdoModifie != nil) // un plafond plus récent n'est pas écrasé
        #expect(fichier.tombstones == nil && fichier.deviceID == nil)

        let autre = try ModelContainer(for: Schema(PactoleSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        #expect(try fichier.restaurer(dans: autre.mainContext).hasSuffix("restauré(s)"))
        #expect(try autre.mainContext.fetch(FetchDescriptor<FraisFixe>()).first?.motifBanque == "abonnement test")
        #expect(try fichier.restaurer(dans: autre.mainContext) == "déjà à jour")
        #expect(PactoleBackup.nomFichier(now: jour(3)) == "Pactole-sauvegarde-2026-10-08")
        #expect((try? PactoleBackup.decode(Data("{}".utf8))) == nil)
    }

    @Test func sixDerniersMois() {
        // jour(0) : lundi 5 octobre 2026. Le 28 avril est hors des six mois (mai → octobre).
        let liste = [depense(40, "courses", jour(1)), depense(10, "courses", jour(-6)), depense(25, "tabac", jour(-40)),
                     depense(99, "courses", jour(-160))]
        let historique = Historique(depenses: liste, fin: jour(0))
        #expect(historique.mois.count == 6)
        let format = Date.FormatStyle(locale: Locale(identifier: "fr_FR"), timeZone: Calendar.francais.timeZone).month(.twoDigits)
        #expect(historique.mois.map { $0.debut.formatted(format) } == ["05", "06", "07", "08", "09", "10"])
        #expect(historique.serie("courses") == [0, 0, 0, 0, 10_00, 40_00])
        #expect(historique.serie("tabac") == [0, 0, 0, 25_00, 0, 0])
        #expect(historique.mois.last?.total == 40_00)
        // Moyenne sur les cinq mois complets (sans octobre, en cours).
        #expect(historique.moyenne("courses", maintenant: jour(0)) == 2_00)
        #expect(historique.moyenne("tabac", maintenant: jour(0)) == 5_00)
    }
}

@MainActor
struct SuiviHebdoTests {
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try ModelContainer(for: Schema(PactoleSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = container.mainContext
        PactoleDatabase.ajouterPostesDeDepart(dans: context)
    }

    /// Même forme que le document de l'artefact (données inventées).
    private let fichier = Data("""
    {"hebdo": 135, "plafonds": {"courses": 300, "imprevu": 0, "jeux": 40},
     "depenses": [
       {"c": "courses", "d": "2026-10-02", "m": 119, "n": "", "t": 1790962253776},
       {"c": "tabac", "d": "2026-10-03", "m": 13, "n": "E.Leclerc (tabac) · Apple Pay", "t": 1791010860000},
       {"c": "imprevu", "d": "2026-10-03", "m": 38.4, "n": "Cadeau · Apple Pay", "t": 1791017220000},
       {"c": "transport", "d": "2026-10-04", "m": 1.55, "t": 1791011640000},
       {"c": "inconnu", "d": "2026-10-05", "m": 4.57, "n": "SPAR", "t": 1791108600000}
     ]}
    """.utf8)

    @Test func importSansDoublon() throws {
        let suivi = try SuiviHebdo.decode(fichier)
        #expect(try suivi.importer(dans: context) == .init(ajoutees: 5, dejaPresentes: 0, ignorees: 0))
        #expect(try suivi.importer(dans: context) == .init(ajoutees: 0, dejaPresentes: 5, ignorees: 0))
        #expect(try context.fetchCount(FetchDescriptor<Depense>()) == 5)
    }

    @Test func montantsNotesEtSources() throws {
        _ = try SuiviHebdo.decode(fichier).importer(dans: context)
        let depenses = try context.fetch(FetchDescriptor<Depense>())
        let tabac = try #require(depenses.first { $0.posteID == "tabac" })
        #expect(tabac.note == "E.Leclerc (tabac)")
        #expect(tabac.source == .applePay)
        #expect(depenses.first { $0.posteID == "transport" }?.montantCentimes == 155)
        #expect(depenses.first { $0.posteID == Poste.imprevu }?.montantCentimes == 38_40)
        // Poste inconnu : rangé dans Divers.
        #expect(depenses.first { $0.note == "SPAR" }?.posteID == Poste.divers)
    }

    @Test func totauxDOctobre() throws {
        _ = try SuiviHebdo.decode(fichier).importer(dans: context)
        let depenses = try context.fetch(FetchDescriptor<Depense>())
        let totaux = Cumuls.parPoste(depenses, mois: Periodes.mois(contenant: SuiviHebdo.date("2026-10-15")!))
        #expect(totaux["courses"] == 119_00)
        #expect(totaux[Poste.imprevu] == 38_40)
        let attendu: Int = 119_00 + 13_00 + 38_40 + 1_55 + 4_57
        #expect(totaux.values.reduce(0, +) == attendu)
    }

    @Test func plafondsRepris() throws {
        _ = try SuiviHebdo.decode(fichier).importer(dans: context)
        let postes = try context.fetch(FetchDescriptor<Poste>())
        #expect(postes.first { $0.syncID == "courses" }?.plafondMensuelCentimes == 300_00)
        #expect(postes.first { $0.syncID == Poste.imprevu }?.plafondMensuelCentimes == nil)
        #expect(postes.first { $0.syncID == "tabac" }?.plafondMensuelCentimes == 150_00) // absent du fichier : inchangé
    }

    @Test func dateAMidi() {
        let date = SuiviHebdo.date("2026-10-05")!
        #expect(Calendar.francais.component(.hour, from: date) == 12)
        #expect(SuiviHebdo.date("pas une date") == nil)
    }
}

struct ClassementTests {
    private let regles = Regle.depart().map { (motif: $0.motif, posteID: $0.posteID) }

    private func classer(_ commercant: String, _ centimes: Int, connus: Set<String> = []) -> Classement.Resultat {
        Classement.classer(commercant: commercant, centimes: centimes, regles: regles, commercantsConnus: connus)
    }

    @Test func normalisation() {
        #expect(Classement.normaliser("E.Leclerc") == "e leclerc")
        #expect(Classement.normaliser("  Intermarché  Orléans ") == "intermarche orleans")
    }

    @Test func leclercTreizeEuros() {
        #expect(classer("E.Leclerc", 13_00) == .init(posteID: "tabac", aVerifier: false))
        #expect(classer("E.Leclerc", 39_00) == .init(posteID: "tabac", aVerifier: false))
        #expect(classer("E.LECLERC ORLEANS", 47_12) == .init(posteID: "courses", aVerifier: true))
    }

    @Test func reglesEtNouveauxCommercants() {
        // Enseigne connue par une règle, mais jamais vue : à vérifier.
        #expect(classer("Burger King", 25_20) == .init(posteID: "restos", aVerifier: true))
        #expect(classer("Burger King", 25_20, connus: ["burger king"]) == .init(posteID: "restos", aVerifier: false))
        #expect(classer("Joueclub La Recre", 38_40, connus: ["joueclub la recre"]).posteID == Poste.divers)
        #expect(classer("PayByPhone", 1_50, connus: ["paybyphone"]) == .init(posteID: "transport", aVerifier: false))
    }

    @Test func doutesEtImprevu() {
        #expect(classer("Boutique inconnue", 10_00) == .init(posteID: Poste.divers, aVerifier: true))
        // Une règle vers Imprévu n'est jamais appliquée.
        let imprevu = Classement.classer(commercant: "Garage", centimes: 300_00, regles: [("garage", Poste.imprevu)],
                                         commercantsConnus: ["garage"])
        #expect(imprevu == .init(posteID: Poste.divers, aVerifier: true))
        // Mot entier seulement.
        #expect(classer("Tabacologue", 10_00).posteID == Poste.divers)
    }

    @Test func regleLaPlusPrecise() {
        let r = Classement.classer(commercant: "Spar Station", centimes: 10_00,
                                   regles: [("spar", "courses"), ("spar station", "transport")], commercantsConnus: ["spar station"])
        #expect(r.posteID == "transport")
    }
}

@MainActor
struct PaiementsTests {
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try ModelContainer(for: Schema(PactoleSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = container.mainContext
        PactoleDatabase.ajouterPostesDeDepart(dans: context)
    }

    @Test func ajoutEtDoublon() throws {
        let date = jour(1, heure: 9)
        #expect(try Paiements.ajouter(commercant: "E.Leclerc", centimes: 13_00, carte: "CB Visa", date: date, dans: context)
                == .ajoutee(posteID: "tabac", aVerifier: false))
        // Même jour, même montant, même commerçant (autre heure) : ignoré.
        #expect(try Paiements.ajouter(commercant: "E. LECLERC", centimes: 13_00, carte: "CB Visa", date: jour(1, heure: 18), dans: context)
                == .doublon)
        // Autre jour : nouvelle dépense.
        #expect(try Paiements.ajouter(commercant: "E.Leclerc", centimes: 13_00, carte: "", date: jour(2), dans: context)
                == .ajoutee(posteID: "tabac", aVerifier: false))
        let depense = try #require(try context.fetch(FetchDescriptor<Depense>()).first)
        #expect(depense.source == .applePay)
        #expect(depense.commercant == "E.Leclerc")
    }

    @Test func doublonAvecLeSuiviHebdo() throws {
        // Dépense reprise du Suivi hebdo : le commerçant est au début de la note.
        let reprise = Depense(montantCentimes: 25_20, posteID: "restos", date: jour(-1), note: "Burger King", source: .applePay)
        context.insert(reprise)
        #expect(try Paiements.ajouter(commercant: "Burger King", centimes: 25_20, carte: "", date: jour(-1, heure: 20), dans: context)
                == .doublon)
    }

    @Test func confirmerApprendLeCommercant() throws {
        _ = try Paiements.ajouter(commercant: "Chez Mario", centimes: 18_00, carte: "", date: jour(0), dans: context)
        let depense = try #require(try context.fetch(FetchDescriptor<Depense>()).first)
        #expect(depense.aVerifier && depense.posteID == Poste.divers)
        try Paiements.confirmer(depense, posteID: "restos", dans: context)
        #expect(!depense.aVerifier && depense.posteID == "restos")
        // Le commerçant est retenu : le paiement suivant est classé sans doute.
        #expect(try Paiements.ajouter(commercant: "Chez Mario", centimes: 22_00, carte: "", date: jour(3), dans: context)
                == .ajoutee(posteID: "restos", aVerifier: false))
    }

    @Test func confirmerEnImprevuNeCreePasDeRegle() throws {
        _ = try Paiements.ajouter(commercant: "Garage Centre", centimes: 300_00, carte: "", date: jour(0), dans: context)
        let depense = try #require(try context.fetch(FetchDescriptor<Depense>()).first)
        let avant = try context.fetchCount(FetchDescriptor<Regle>())
        try Paiements.confirmer(depense, posteID: Poste.imprevu, dans: context)
        #expect(try context.fetchCount(FetchDescriptor<Regle>()) == avant)
    }

    @Test func fichierDeSecours() throws {
        let csv = """
        date;commercant;montant;carte

        2026-10-06 09:01;E.Leclerc;13,00 €;CB Visa
        2026-10-06 10:47;Joueclub La Recre;38,40 €;CB Visa
        pas;une;ligne
        """
        var traitees = Set<String>()
        #expect(try Paiements.lireCSV(csv, traitees: &traitees, dans: context) == .init(ajoutees: 2, doublons: 0, illisibles: 1))
        // Lignes déjà lues : ignorées.
        #expect(try Paiements.lireCSV(csv, traitees: &traitees, dans: context) == .init(ajoutees: 0, doublons: 0, illisibles: 1))
        // Sans mémoire, les doublons sont quand même reconnus.
        var vide = Set<String>()
        #expect(try Paiements.lireCSV(csv, traitees: &vide, dans: context) == .init(ajoutees: 0, doublons: 2, illisibles: 1))
        #expect(Paiements.dateCSV("2026-10-06 09:01").map { Calendar.francais.component(.hour, from: $0) } == 9)
    }

    @Test func montantDeRaccourcis() {
        #expect(Montant.centimes(depuis: "13,00\u{00A0}€") == 13_00)
        #expect(Montant.centimes(depuis: "€13.00") == 13_00)
        #expect(Montant.centimes(depuis: "-13,00 €") == nil)
    }
}

@MainActor
struct ActionRaccourcisTests {
    @Test func pointVirguleToleré() throws {
        // Base réelle du module : paiement daté de 2001 pour ne rien mélanger aux dépenses du simulateur, puis supprimé.
        let date = Date(timeIntervalSinceReferenceDate: 3600)
        let context = PactoleDatabase.container.mainContext
        // Reste d'un passage interrompu : on repart de zéro.
        try context.fetch(FetchDescriptor<Depense>()).filter { $0.date == date }.forEach(context.delete)
        try context.save()
        let message = try PactoleKit.ajouterPaiement(commercant: "Test Égide;", montant: "1,23 €;", carte: "CB Visa;", date: date)
        #expect(message.hasPrefix("1,23"))
        let ajoutees = try context.fetch(FetchDescriptor<Depense>()).filter { $0.date == date }
        #expect(ajoutees.map(\.commercant) == ["Test Égide"])
        #expect(ajoutees.map(\.carte) == ["CB Visa"])
        ajoutees.forEach(context.delete)
        try context.save()
    }
}

@MainActor
struct SuppressionTests {
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try ModelContainer(for: Schema(PactoleSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = container.mainContext
        PactoleDatabase.ajouterPostesDeDepart(dans: context)
    }

    /// Bug du 5 octobre : un paiement supprimé revenait à chaque relecture de transactions.csv.
    @Test func paiementSupprimeNeRevientPas() throws {
        let csv = "date;commercant;montant;carte\n2026-10-03 10:47;Joueclub La Recre;38,40 €;CB Visa"
        var traitees = Set<String>()
        _ = try Paiements.lireCSV(csv, traitees: &traitees, dans: context)
        let depenses = try context.fetch(FetchDescriptor<Depense>())
        #expect(depenses.count == 1)
        depenses.forEach(context.delete)
        try context.save()
        #expect(try Paiements.lireCSV(csv, traitees: &traitees, dans: context) == .init())
        #expect(try context.fetchCount(FetchDescriptor<Depense>()) == 0)
    }

    /// Même achat repris du Suivi hebdo avec une autre note : reconnu comme doublon.
    @Test func doublonAvecUneNoteDifferente() throws {
        context.insert(Depense(montantCentimes: 38_40, posteID: Poste.imprevu, date: jour(-2), note: "Joueclub — cadeau filleul",
                               source: .applePay))
        #expect(try Paiements.ajouter(commercant: "Joueclub La Recre", centimes: 38_40, carte: "", date: jour(-2, heure: 10),
                                      dans: context) == .doublon)
        // Autre commerçant, même jour et même montant : pas un doublon.
        #expect(try Paiements.ajouter(commercant: "Fnac", centimes: 38_40, carte: "", date: jour(-2), dans: context)
                != .doublon)
    }

    @Test func memeCommercant() {
        #expect(Paiements.memeCommercant("joueclub la recre", "joueclub cadeau filleul"))
        #expect(Paiements.memeCommercant("burger king", "burger king"))
        #expect(!Paiements.memeCommercant("spar", "super u"))
        #expect(!Paiements.memeCommercant("le cafe", "le marche")) // « le » : moins de 3 lettres
    }
}

/// Deux appareils simulés (deux bases en mémoire) qui s'échangent leurs fichiers de synchro.
@MainActor
struct SynchroTests {
    let iphone: ModelContext
    let mac: ModelContext
    let containers: [ModelContainer]

    init() throws {
        let a = try ModelContainer(for: Schema(PactoleSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let b = try ModelContainer(for: Schema(PactoleSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers = [a, b]
        iphone = a.mainContext
        mac = b.mainContext
        PactoleDatabase.ajouterPostesDeDepart(dans: iphone)
        PactoleDatabase.ajouterPostesDeDepart(dans: mac)
    }

    private func fichier(_ context: ModelContext, _ appareil: String) throws -> PactoleBackup {
        var f = try PactoleSync.shared.snapshot(of: context)
        f.deviceName = appareil
        return try PactoleBackup.decode(try f.encoded()) // passage par le JSON, comme sur le disque
    }

    private func echanger() throws {
        let deIphone = try fichier(iphone, "iPhone"), deMac = try fichier(mac, "Mac")
        try PactoleSync.merge([deMac], into: iphone)
        try PactoleSync.merge([deIphone], into: mac)
    }

    private func depenses(_ context: ModelContext) throws -> [Depense] { try context.fetch(FetchDescriptor<Depense>()) }

    @Test func creationEtModification() throws {
        let d = Depense(montantCentimes: 12_00, posteID: "courses", date: jour(1))
        iphone.insert(d)
        try iphone.save()
        try echanger()
        #expect(try depenses(mac).map(\.montantCentimes) == [12_00])

        // Modification sur le Mac, plus récente : elle gagne.
        let surMac = try #require(try depenses(mac).first)
        surMac.montantCentimes = 15_00
        surMac.modifiedAt = .now.addingTimeInterval(5)
        try mac.save()
        try echanger()
        #expect(try depenses(iphone).map(\.montantCentimes) == [15_00])
        // Postes de départ jamais en double.
        #expect(try mac.fetchCount(FetchDescriptor<Poste>()) == Poste.depart().count)
    }

    @Test func suppression() throws {
        let d = Depense(montantCentimes: 8_00, posteID: "tabac", date: jour(1))
        iphone.insert(d)
        try iphone.save()
        try echanger()
        #expect(try depenses(mac).count == 1)

        Suppressions.supprimer(try #require(try depenses(mac).first), dans: mac)
        try mac.save()
        try echanger()
        #expect(try depenses(iphone).isEmpty)
        // Et elle ne revient pas : l'iPhone ne la renvoie plus.
        try echanger()
        #expect(try depenses(mac).isEmpty)
    }

    @Test func modificationPlusRecenteQueLaSuppression() throws {
        let d = Depense(montantCentimes: 8_00, posteID: "tabac", date: jour(1))
        iphone.insert(d)
        try iphone.save()
        try echanger()
        Suppressions.supprimer(try #require(try depenses(mac).first), dans: mac)
        try mac.save()
        // Pendant ce temps, l'iPhone modifie la dépense après la suppression.
        d.montantCentimes = 9_00
        d.modifiedAt = .now.addingTimeInterval(10)
        try iphone.save()
        try echanger()
        #expect(try depenses(iphone).map(\.montantCentimes) == [9_00])
        #expect(try depenses(mac).map(\.montantCentimes) == [9_00])
    }

    @Test func regleSupprimee() throws {
        let regle = Regle(motif: "chez mario", posteID: "restos")
        iphone.insert(regle)
        try iphone.save()
        try echanger()
        #expect(try mac.fetch(FetchDescriptor<Regle>()).contains { $0.motif == "chez mario" })
        Suppressions.supprimer(regle, dans: iphone)
        try iphone.save()
        try echanger()
        #expect(!(try mac.fetch(FetchDescriptor<Regle>()).contains { $0.motif == "chez mario" }))
    }

    @Test func fichiersDuDossier() throws {
        let dossier = FileManager.default.temporaryDirectory.appending(path: "money-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dossier) }
        try fichier(iphone, "iPhone").encoded().write(to: dossier.appending(path: "depenses-iphone-aaaa.json"))
        try fichier(mac, "Mac").encoded().write(to: dossier.appending(path: "depenses-mac-bbbb.json"))
        try Data("pas du json".utf8).write(to: dossier.appending(path: "depenses-casse-cccc.json"))
        try Data("{}".utf8).write(to: dossier.appending(path: "idees-iphone-dddd.json"))
        let lus = try PactoleSync.readRemoteFiles(in: dossier, excluding: "depenses-mac-bbbb.json")
        #expect(lus.compactMap(\.deviceName) == ["iPhone"]) // ni son propre fichier, ni Muse, ni un fichier abîmé
    }
}

@MainActor
struct Phase5Tests {
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try ModelContainer(for: Schema(PactoleSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = container.mainContext
        PactoleDatabase.ajouterPostesDeDepart(dans: context)
    }

    @Test func bilanDuMois() {
        let depenses = [Depense(montantCentimes: 100_00, posteID: "courses", date: jour(1)),
                        Depense(montantCentimes: 40_00, posteID: "courses", date: jour(-30)), // septembre
                        Depense(montantCentimes: 50_00, posteID: Poste.imprevu, date: jour(2))]
        let frais = [FraisFixe(nom: "Netflix", montantCentimes: 21_99, jour: 11, categorie: .abonnement),
                     FraisFixe(nom: "Ancien", montantCentimes: 10_00, jour: 1, categorie: .abonnement)]
        frais[1].actif = false
        let revenus = [Revenu(mois: "2026-10", libelle: "Salaire", montantCentimes: 1_862_91),
                       Revenu(mois: "2026-09", libelle: "Salaire", montantCentimes: 1_854_43)]
        let bilan = BilanMois.calculer(mois: jour(0), depenses: depenses, frais: frais, revenus: revenus)
        #expect(bilan.revenus == 1_862_91)
        #expect(bilan.fraisFixes == 21_99) // l'abonnement arrêté ne compte pas
        #expect(bilan.budgetVariable == 1_840_92)
        #expect(bilan.depenses == 150_00) // imprévu compris
        #expect(bilan.reste == 1_690_92)
        #expect(bilan.ecart("courses") == 60_00)
        #expect(bilan.ecart("tabac") == 0)
    }

    @Test func fraisAnnuelPasDansLeBilan() throws {
        let dashlane = FraisFixe(nom: "Dashlane", montantCentimes: 57_49, jour: 7, categorie: .abonnement)
        dashlane.moisAnnuel = 10
        let netflix = FraisFixe(nom: "Netflix", montantCentimes: 21_99, jour: 11, categorie: .abonnement)
        let octobre = BilanMois.calculer(mois: jour(0), depenses: [], frais: [dashlane, netflix], revenus: [])
        let septembre = BilanMois.calculer(mois: jour(-30), depenses: [], frais: [dashlane, netflix], revenus: [])
        #expect(octobre.fraisFixes == 21_99) // payé comme une dépense, pas compté deux fois
        #expect(septembre.fraisFixes == 21_99)
        #expect(dashlane.echeance == "le 7 octobre, chaque année")

        // Passe par la synchro, et un ancien fichier sans le champ reste mensuel.
        context.insert(dashlane)
        let data = try JSONEncoder().encode(try PactoleBackup.make(from: context))
        let copie = try JSONDecoder().decode(PactoleBackup.self, from: data)
        #expect(copie.fraisFixes?.first?.moisAnnuel == 10)
        let ancien = #"{"syncID":"a","nom":"Loyer","montantCentimes":1,"jour":1,"categorie":"logement","actif":true,"modifiedAt":0}"#
        #expect(try JSONDecoder().decode(PactoleBackup.FraisRecord.self, from: Data(ancien.utf8)).moisAnnuel == nil)
    }

    @Test func alerteA80Pourcent() {
        #expect(AlertePlafond.franchit(totalAvant: 250_00, ajout: 10_00, plafond: 320_00)) // 256 € = 80 %
        #expect(!AlertePlafond.franchit(totalAvant: 200_00, ajout: 10_00, plafond: 320_00))
        #expect(!AlertePlafond.franchit(totalAvant: 260_00, ajout: 10_00, plafond: 320_00)) // déjà au-dessus : une seule alerte
        #expect(!AlertePlafond.franchit(totalAvant: 0, ajout: 500_00, plafond: nil))
    }

    @Test func prochainDimanche() {
        let lundi = jour(0, heure: 9)
        let dimanche = Dimanche.prochain(apres: lundi)
        #expect(Calendar.francais.component(.weekday, from: dimanche) == 1)
        #expect(Calendar.francais.component(.hour, from: dimanche) == 20)
        #expect(Calendar.francais.isDate(dimanche, inSameDayAs: jour(6)))
        // Dimanche à 21 h : le suivant.
        #expect(Calendar.francais.isDate(Dimanche.prochain(apres: jour(6, heure: 21)), inSameDayAs: jour(13)))
    }

    @Test func cleDeMois() {
        #expect(Revenu.cle(jour(0)) == "2026-10")
        #expect(RevenusView.titre("2026-10") == "Octobre 2026")
    }

    @Test func synchroDesFraisEtRevenus() throws {
        let autre = try ModelContainer(for: Schema(PactoleSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let netflix = FraisFixe(nom: "Netflix", montantCentimes: 21_99, jour: 11, categorie: .abonnement)
        context.insert(netflix)
        context.insert(Revenu(mois: "2026-10", libelle: "Salaire", montantCentimes: 1_862_91))
        try context.save()
        try PactoleSync.merge([try PactoleSync.shared.snapshot(of: context)], into: autre.mainContext)
        #expect(try autre.mainContext.fetch(FetchDescriptor<FraisFixe>()).map(\.nom) == ["Netflix"])
        #expect(try autre.mainContext.fetch(FetchDescriptor<Revenu>()).map(\.montantCentimes) == [1_862_91])
        // Suppression transmise.
        Suppressions.supprimer(netflix, dans: context)
        try context.save()
        try PactoleSync.merge([try PactoleSync.shared.snapshot(of: context)], into: autre.mainContext)
        #expect(try autre.mainContext.fetchCount(FetchDescriptor<FraisFixe>()) == 0)
    }
}

@MainActor
struct FraisProTests {
    /// Base d'avant la mise à jour (7 postes) : Frais pro est ajouté, une seule fois, sans toucher aux autres.
    @Test func posteAjouteAUneBaseExistante() throws {
        let container = try ModelContainer(for: Schema(PactoleSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        Poste.depart().filter { $0.syncID != "pro" }.forEach(context.insert)
        let courses = try #require(try context.fetch(FetchDescriptor<Poste>()).first { $0.syncID == "courses" })
        courses.plafondMensuelCentimes = 300_00
        PactoleDatabase.ajouterPostesDeDepart(dans: context)
        PactoleDatabase.ajouterPostesDeDepart(dans: context)
        let postes = try context.fetch(FetchDescriptor<Poste>())
        #expect(postes.filter { $0.syncID == "pro" }.count == 1)
        #expect(postes.first { $0.syncID == "pro" }?.horsPlafondHebdo == true)
        #expect(courses.plafondMensuelCentimes == 300_00)
    }
}

struct RecuTests {
    private let maintenant = Calendar.francais.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 9))!

    private func jour(_ d: Date?) -> DateComponents? {
        d.map { Calendar.francais.dateComponents([.year, .month, .day], from: $0) }
    }

    @Test func dashlane() {
        let texte = """
        Merci d’avoir choisi
        Dashlane
        Créez votre compte pour rendre votre vie en ligne plus sûre et plus simple.
        Récapitulatif de la commande
        Total 57,49 €
        Acheté le 7 octobre 2026
        Abonnement annuel 57,49 €
        Sous-total 57,49 €
        VISA se terminant par ••••9321 57,49 €
        """
        let b = Recu.analyser(texte, maintenant: maintenant)
        #expect(b.centimes == 57_49)
        #expect(jour(b.date) == DateComponents(year: 2026, month: 10, day: 7))
        #expect(b.commercant == "Dashlane")
        #expect(b.carte == "Visa 9321")
    }

    @Test func paypalSteam() {
        let texte = """
        PayPal
        Vous avez envoyé un paiement de 17,99 EUR à Valve Corporation
        Transaction effectuée le 6 oct. 2026
        Steam Purchase
        Payé avec PayPal
        """
        let b = Recu.analyser(texte, maintenant: maintenant)
        #expect(b.centimes == 17_99)
        #expect(b.commercant == "Valve Corporation")
        #expect(b.carte == "PayPal")
    }

    @Test func dateNumeriqueEtMontantSeul() {
        let b = Recu.analyser("PayByPhone\nStationnement Orléans\nDate : 05/10/2026 14:02\n€ 2.40", maintenant: maintenant)
        #expect(b.centimes == 2_40)
        #expect(jour(b.date) == DateComponents(year: 2026, month: 10, day: 5))
        #expect(b.commercant == "PayByPhone")
    }

    @Test func captureSansBarreDEtat() {
        #expect(Recu.commercant(["13:00 •ll 5G •", "Etat : accepté", "Boulangerie Calvi", "Total 17,50 €"]) == "Boulangerie Calvi")
    }

    @Test func totalSurLaLigneSuivanteEtGrandsMontants() {
        #expect(Recu.montant(["Sous-total", "10,00 €", "Total", "1 234,50 €"]) == 1_234_50)
        #expect(Recu.montants("Montant : 12.5 €").isEmpty) // deux décimales attendues
    }

    @Test func mailHTML() {
        let brut = "<html><body><p>Merci d&#39;avoir choisi Dashlane</p><td>Total</td><td>57,49&nbsp;&euro;</td></body></html>"
        let texte = LectureRecu.texteBrut(brut)
        #expect(Recu.analyser(texte, maintenant: maintenant).centimes == 57_49)
    }
}

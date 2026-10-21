import Foundation
import Testing
@testable import HephaistosKit

struct HephaistosKitTests {
    @Test func famillesDesCles() {
        #expect(Famille.smc("Tp0e") == .processeur)
        #expect(Famille.smc("Tg0k") == .graphique)
        #expect(Famille.smc("TB1T") == .batterie)
        #expect(Famille.smc("TCMz") == .autreSMC)
        #expect(Famille.hid("NAND CH0 temp") == .ssd)
        #expect(Famille.hid("gas gauge battery") == .batterie)
        #expect(Famille.hid("PMU tdie1") == .autreHID)
    }

    @Test func resumeSousCharge() {
        let releve = Releve(date: .now, smc: ["Tp00": 76, "Tp0e": 92, "Tg0k": 64, "TB1T": 28, "TCMz": 99], ssd: 33)
        #expect(releve.processeurMoyenne == 84)
        #expect(releve.processeurMax == 92)
        #expect(releve.graphique == 64)
        #expect(releve.batterie == 28)
        #expect(releve.ssd == 33)
        #expect(releve.plusChaud == 92)
    }

    @Test func puceGraphiqueEndormieEtValeursAbsurdes() {
        // Au repos les clés Tg lisent moins que la batterie ; un capteur débranché renvoie 0 ou −9201.
        let releve = Releve(date: .now, smc: ["Tp00": 40, "Tp01": 0, "Tp02": -9201, "Tg0k": 16, "TB1T": 28], ssd: -9201)
        #expect(releve.processeurMoyenne == 40)
        #expect(releve.graphique == nil)
        #expect(releve.ssd == nil)
        #expect(releve.plusChaud == 40)
        #expect(Releve(date: .now, smc: [:]).plusChaud == nil)
    }

    @Test func puceGraphiqueLaPlusChaude() {
        let releve = Releve(date: .now, smc: ["Tp00": 70, "Tg0k": 87, "TB1T": 29])
        #expect(releve.plusChaud == 87)
        #expect(Affichage.plusChaud.degres(releve) == 87)
        #expect(Affichage.processeur.degres(releve) == 70)
    }

    @Test func texteDeLaBarre() {
        #expect(HephaistosModele.texte(61.6) == "62°")
        #expect(HephaistosModele.texte(nil) == "–")
    }

    @Test func moyenneGlissante() {
        #expect(HephaistosModele.moyenne([50, 75, 52, 74, 49]) == 60)
        #expect(HephaistosModele.moyenne([]) == nil)
    }

    @Test func historiqueGlissant() {
        let debut = Date(timeIntervalSince1970: 1_000)
        var historique: [HephaistosModele.Point] = []
        for seconde in stride(from: 0.0, through: 20, by: 2) {
            historique = HephaistosModele.ajouter(.init(date: debut + seconde, degres: seconde), a: historique, duree: 10)
        }
        #expect(historique.map(\.degres) == [10, 12, 14, 16, 18, 20])
    }

    @Test func valeursSMC() {
        #expect(SMC.code("TB1T") == 0x5442_3154)
        #expect(SMC.texte(0x5442_3154) == "TB1T")
        #expect(SMC.nombre(type: "flt ", octets: [0x00, 0x00, 0x28, 0x42]) == 42) // petit-boutiste
        #expect(SMC.nombre(type: "ui16", octets: [0x09, 0x0d]) == 2317)
        #expect(SMC.nombre(type: "sp78", octets: [0x1e, 0x80]) == 30.5)
        #expect(SMC.nombre(type: "ui8 ", octets: [1]) == 1)
        #expect(SMC.nombre(type: "ch8*", octets: [1]) == nil)
    }

    @Test func chargeDuProcesseur() {
        #expect(ChargeProcesseur.part(avant: .init(actif: 100, total: 1000), apres: .init(actif: 150, total: 1200)) == 0.25)
        #expect(ChargeProcesseur.part(avant: .init(actif: 100, total: 1000), apres: .init(actif: 100, total: 1000)) == nil)
    }

    @Test func ventilateur() {
        #expect(Ventilateur(toursParMinute: 0, mini: 2317, maxi: 6550).part == 0)
        #expect(Ventilateur(toursParMinute: 3275, mini: 2317, maxi: 6550).part == 0.5)
    }

    /// Secondes auxquelles l'alerte part, pour une suite de mesures (seconde, température).
    private func alertes(_ mesures: [(Double, Double)], reglages: ReglagesAlerte) -> [Double] {
        var veille = Veille()
        let debut = Date(timeIntervalSince1970: 1_000)
        return mesures.filter { veille.observer($0.1, le: debut + $0.0, reglages: reglages) }.map(\.0)
    }

    private func palier(_ degres: Double, de debut: Double, a fin: Double) -> [(Double, Double)] {
        stride(from: debut, through: fin, by: 2).map { ($0, degres) }
    }

    @Test func alerteApresLaDureeEtUneSeuleFois() {
        let reglages = ReglagesAlerte(active: true, seuil: 95, duree: 120)
        // 96 °C tenus 10 minutes : une seule alerte, au bout de 2 minutes.
        #expect(alertes(palier(96, de: 0, a: 600), reglages: reglages) == [120])
        // Redescendre juste sous le seuil (92 °C) puis remonter ne relance pas l'alerte ; une fois redescendu
        // de 5 °C sous le seuil (89 °C), un nouvel épisode alerte de nouveau après 2 minutes.
        let mesures = palier(96, de: 0, a: 600) + [(602, 92)] + palier(97, de: 604, a: 900) + [(902, 89)] + palier(96, de: 904, a: 1_100)
        #expect(alertes(mesures, reglages: reglages) == [120, 1_024])
    }

    @Test func picCourtSansAlerte() {
        let reglages = ReglagesAlerte(active: true, seuil: 95, duree: 120)
        // 100 s au-dessus, un creux à 94 °C, puis au-dessus : le décompte repart de zéro après le creux.
        let mesures = palier(98, de: 0, a: 98) + [(100, 94)] + palier(98, de: 102, a: 300)
        #expect(alertes(mesures, reglages: reglages) == [222])
    }

    @Test func alerteCoupeeOuMacEnVeille() {
        #expect(alertes(palier(100, de: 0, a: 120), reglages: ReglagesAlerte(active: false, seuil: 95, duree: 30)).isEmpty)
        // Une heure de veille du Mac ne compte pas comme une heure au-dessus du seuil.
        let mesures = [(200.0, 100.0)] + palier(100, de: 3_800, a: 3_900)
        #expect(alertes(mesures, reglages: ReglagesAlerte(active: true, seuil: 95, duree: 30)) == [3_830])
    }

    @Test func appsLesPlusGourmandes() {
        // 100 : un jeu et son auxiliaire (fils) ; 200 : un navigateur dont l'auxiliaire 201 est lancé à part
        // (fils du système, rattaché par son responsable) ; 300 : un outil sans app.
        let processus: [pid_t: Gourmands.Processus] = [
            100: .init(nom: "Jeu", parent: 1, temps: 2.0),
            101: .init(nom: "Jeu Helper", parent: 100, temps: 1.0),
            200: .init(nom: "Navigateur", parent: 1, temps: 0.2),
            201: .init(nom: "WebContent", parent: 1, responsable: 200, temps: 0.6),
            300: .init(nom: "mdworker", parent: 1, temps: 0.4),
            301: .init(nom: "endormi", parent: 1, temps: 0),
        ]
        let classement = Gourmands.classement(processus, secondes: 2, apps: [100: "Le Jeu", 200: "Navigateur"], premierPlan: 100)
        #expect(classement == [
            Consommation(nom: "Le Jeu", coeurs: 1.5, auPremierPlan: true),
            Consommation(nom: "Navigateur", coeurs: 0.4),
            Consommation(nom: "mdworker", coeurs: 0.2),
        ])
        #expect(classement[0].texte == "150 % d'un cœur")
        #expect(Gourmands.lisible("22.11.0", chemin: "/Users/moi/.local/share/node/versions/22.11.0") == "node")
        #expect(Gourmands.lisible("mdworker", chemin: "/usr/libexec/mdworker") == "mdworker")
        #expect(Gourmands.lisible("42", chemin: "/42") == "42")
    }

    @Test func diagnosticNormalOuAnormal() {
        let jeu = Consommation(nom: "Le Jeu", coeurs: 3.1, auPremierPlan: true)
        let fond = Consommation(nom: "Sauvegarde", coeurs: 1.2)
        let calme = Consommation(nom: "Notes", coeurs: 0.1, auPremierPlan: true)
        #expect(Diagnostic([jeu, fond]) == .premierPlan(jeu))
        #expect(Diagnostic([fond, calme]) == .arrierePlan(fond))
        #expect(Diagnostic([calme]) == .aucune(calme))
        #expect(Diagnostic([]) == .aucune(nil))
        let alerte = Alerte(date: .now, degres: 96.4, reglages: .parDefaut, diagnostic: Diagnostic([jeu]))
        #expect(alerte.titre == "Mac chaud : 96°")
        #expect(alerte.message == "Au-dessus de 95° depuis 2 min. Normal sous forte charge : « Le Jeu », au premier plan, utilise 310 % d'un cœur.")
        #expect(ReglagesAlerte.texte(duree: 30) == "30 s")
    }
}

struct PublicationTests {
    @Test func envoiAuFormatDuServeur() throws {
        let releve = Releve(date: .now, smc: ["Tp00": 60], ventilateurs: [Ventilateur(toursParMinute: 2400, mini: 2317, maxi: 6550)], charge: 0.25)
        let alerte = AlerteDistante(degres: 96, titre: "Mac chaud : 96°", resume: "Au-dessus de 95° depuis 2 min.", detail: "Anormal.", essai: false)
        let json = try JSONEncoder().encode(HephaistosModele.publication(releve, degres: 61.4, alerte: alerte))
        let objet = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(objet["degrees"] as? Double == 61.4)
        #expect(objet["fanRpm"] as? Double == 2400)
        #expect(objet["fanMax"] as? Double == 6550)
        #expect(objet["load"] as? Double == 0.25)
        let envoyee = try #require(objet["alert"] as? [String: Any])
        #expect(envoyee["summary"] as? String == "Au-dessus de 95° depuis 2 min.")
        #expect(envoyee["at"] == nil && envoyee["test"] == nil)
    }

    @Test func lectureDeLaReponseDuServeur() throws {
        let json = Data(#"{"at":"2026-10-12T14:30:00Z","degrees":61.5,"fanRpm":0,"fanMax":6550,"load":0.2,"history":[{"at":"2026-10-12T14:29:00Z","degrees":60},{"at":"2026-10-12T14:30:00Z","degrees":61.5}],"alert":{"at":"2026-10-12T13:00:00Z","degrees":96,"title":"Mac chaud : 96°","summary":"s","detail":"d"}}"#.utf8)
        let etat = try EtatDistant(json: json)
        let mesure = try #require(etat.date)
        #expect(etat.historique.count == 2 && etat.alerte?.degres == 96)
        #expect(etat.carteGraphique == nil)
        #expect(etat.resume(a: mesure.addingTimeInterval(20)) == "62° · à l'instant")
        #expect(etat.resume(a: mesure.addingTimeInterval(130)) == "62° · il y a 2 min")
        #expect(etat.muet(a: mesure.addingTimeInterval(600)))
        #expect(etat.resume(a: mesure.addingTimeInterval(600))?.hasPrefix("Mac en veille ou éteint") == true)
    }

    @Test func carteGraphique() throws {
        let carte = try #require(Accelerateur.carte(["Device Utilization %": 23, "In use system memory": 650_117_120, "Tiler Utilization %": 90]))
        #expect(carte.utilisation == 0.23)
        #expect(carte.texte.hasPrefix("23") && carte.texte.hasSuffix("% · 620 Mo"))
        #expect(Accelerateur.carte(["Device Utilization %": 140])?.utilisation == 1)
        #expect(Accelerateur.carte(["In use system memory": 1]) == nil)
        var releve = Releve(date: .now, smc: [:])
        releve.carteGraphique = carte
        let json = try JSONEncoder().encode(HephaistosModele.publication(releve, degres: 50))
        let objet = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let gpu = try #require(objet["gpu"] as? [String: Any])
        #expect(gpu["use"] as? Double == 0.23 && gpu["memory"] as? Double == 650_117_120)
        let etat = try EtatDistant(json: Data(#"{"degrees":50,"fanRpm":0,"fanMax":0,"load":0,"gpu":{"use":0.23,"memory":650117120},"history":[]}"#.utf8))
        #expect(etat.carteGraphique == carte)
    }

    @Test func serveurSansMesure() throws {
        let etat = try EtatDistant(json: Data(#"{"degrees":0,"fanRpm":0,"fanMax":0,"load":0,"history":[]}"#.utf8))
        #expect(etat.date == nil && etat.resume() == nil)
    }
}

struct RessourcesTests {
    @Test func memoireUtilisee() {
        // Pages de 16 Ko sur 16 Go : 400 000 pages d'apps (dont 50 000 reprenables), 100 000 réservées, 50 000 compressées.
        let memoire = Ressources.memoire(interne: 400_000, purgeable: 50_000, reservee: 100_000, compressee: 50_000,
                                         page: 16_384, totale: 17_179_869_184, niveau: 2)
        #expect(memoire.utilisee == 500_000 * 16_384)
        #expect(memoire.pression == .elevee)
        #expect(memoire.texte == "7,6 Go sur 16 Go")
        #expect(Ressources.memoire(interne: 1, purgeable: 5, reservee: 0, compressee: 0, page: 16_384, totale: 1 << 34, niveau: 1).utilisee == 0)
        #expect(Ressources.memoire(interne: 0, purgeable: 0, reservee: 0, compressee: 0, page: 16_384, totale: 1 << 34, niveau: 4).pression == .critique)
    }

    @Test func tailles() {
        #expect(Taille.memoire(512 * 1_048_576) == "512 Mo")
        #expect(Taille.memoire(3.25 * 1_073_741_824) == "3,2 Go")
        #expect(Taille.disque(494.38e9) == "494 Go")
        #expect(Taille.disque(12.44e9) == "12,4 Go")
        #expect(Disque(libre: 123.5e9, total: 494e9).texte == "124 Go libres sur 494 Go")
        #expect(Disque(libre: 100e9, total: 400e9).part == 0.75)
    }

    @Test func appsLesPlusGrosses() {
        let giga = 1_073_741_824.0
        let processus: [pid_t: Gourmands.Processus] = [
            100: .init(nom: "Navigateur", parent: 1, temps: giga),
            101: .init(nom: "WebContent", parent: 1, responsable: 100, temps: 2 * giga),
            200: .init(nom: "Notes", parent: 1, temps: giga / 2),
            300: .init(nom: "mdworker", parent: 1, temps: giga),
            400: .init(nom: "Jeu", parent: 1, temps: 4 * giga),
            500: .init(nom: "petit", parent: 1, temps: 1_000),
        ]
        let classement = Ressources.classement(processus, apps: [100: "Navigateur", 200: "Notes", 400: "Le Jeu"])
        #expect(classement == [Occupation(nom: "Le Jeu", octets: 4 * giga), Occupation(nom: "Navigateur", octets: 3 * giga), Occupation(nom: "mdworker", octets: giga)])
    }

    @Test func uneAlerteParEpisode() {
        var episode = Episode()
        func alerte(_ seconde: Double, depasse: Bool, rearme: Bool = false) -> Bool {
            episode.observer(depasse: depasse, rearme: rearme, le: Date(timeIntervalSinceReferenceDate: seconde), duree: 120)
        }
        #expect(!alerte(0, depasse: true) && !alerte(20, depasse: true))
        // Retour bref à la normale : le décompte repart de zéro.
        #expect(!alerte(40, depasse: false, rearme: true))
        #expect((3...8).allSatisfy { !alerte(Double($0) * 20, depasse: true) })
        #expect(alerte(180, depasse: true))
        #expect(!alerte(200, depasse: true))
        // Sans retour net à la normale, pas de seconde alerte.
        #expect(!alerte(220, depasse: false))
        #expect((12...20).allSatisfy { !alerte(Double($0) * 20, depasse: true) })
    }

    @Test func textesDesAlertes() {
        let memoire = Memoire(utilisee: 15.5 * 1_073_741_824, totale: 16 * 1_073_741_824, pression: .critique)
        let avis = Avis.memoire(memoire, apps: [Occupation(nom: "Le Jeu", octets: 6 * 1_073_741_824)], le: .now)
        #expect(avis.titre == "Mémoire saturée : 15,5 Go sur 16 Go")
        #expect(avis.message == "Pression critique depuis 2 min. Les plus grosses apps : « Le Jeu » (6 Go).")
        let disque = Avis.disque(Disque(libre: 12.44e9, total: 494e9), seuil: 20, le: .now)
        #expect(disque.titre == "Disque presque plein : 12,4 Go libres")
        #expect(disque.message == "Moins de 20 Go libres sur 494 Go.")
        #expect(disque.sorte.distante == "disk" && avis.sorte.distante == "memory")
    }

    @Test func envoiEtLectureAuFormatDuServeur() throws {
        var releve = Releve(date: .now, smc: ["Tp00": 60])
        releve.memoire = Memoire(utilisee: 8e9, totale: 16e9, pression: .elevee)
        releve.disque = Disque(libre: 100e9, total: 494e9)
        let publication = HephaistosModele.publication(releve, degres: 60, apps: [Occupation(nom: "Le Jeu", octets: 4e9)])
        let objet = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(publication)) as? [String: Any])
        #expect((objet["memory"] as? [String: Any])?["pressure"] as? Int == 1)
        #expect((objet["disk"] as? [String: Any])?["free"] as? Double == 100e9)
        #expect((objet["memoryApps"] as? [[String: Any]])?.first?["name"] as? String == "Le Jeu")
        let json = Data(#"{"at":"2026-10-13T09:00:00Z","degrees":60,"fanRpm":0,"fanMax":6550,"load":0.2,"memory":{"used":8e9,"total":16e9,"pressure":1},"memoryApps":[{"name":"Le Jeu","bytes":4e9}],"disk":{"free":100e9,"total":494e9},"history":[],"alert":{"at":"2026-10-13T08:00:00Z","degrees":0,"title":"t","summary":"s","detail":"","kind":"disk"}}"#.utf8)
        let etat = try EtatDistant(json: json)
        #expect(etat.memoire == releve.memoire && etat.disque == releve.disque && etat.appsMemoire?.first?.octets == 4e9)
        #expect(etat.alerte?.sorte == "disk")
    }
}

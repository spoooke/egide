import Foundation
import Testing
@testable import CerbereKit

/// Phase 5 : audits demandés depuis Égide sur l'iPhone. Rien n'est contacté : le serveur et l'audit sont des faux.
struct DistantTests {
    @Test func liensPublicsAcceptesEtRamenesAuDepot() throws {
        #expect(try CibleDistante("https://github.com/Auteur/Depot") == .lien("https://github.com/Auteur/Depot", hote: "github.com"))
        // La page ouverte dans Safari n'est pas l'adresse du dépôt.
        #expect(try CibleDistante(" https://www.github.com/auteur/depot/tree/main/src?tab=readme#installation\n").cible == "https://github.com/auteur/depot")
        #expect(try CibleDistante("https://gitlab.com/groupe/sous-groupe/depot/-/blob/main/setup.py").cible == "https://gitlab.com/groupe/sous-groupe/depot")
        #expect(try CibleDistante("https://codeberg.org/auteur/depot.git/").cible == "https://codeberg.org/auteur/depot.git")
        #expect(try CibleDistante("pypi:requests") == .paquet("requests"))
        #expect(try CibleDistante("https://pypi.org/project/zope.interface/#files").cible == "pypi:zope.interface")
        #expect(try CibleDistante("pypi:requests").domaines == ["pypi.org", "files.pythonhosted.org"])
    }

    @Test(arguments: [
        "", "   ", "depot", "/Users/moi/Documents", "~/Desktop/secret", "file:///etc/passwd", "ssh://git@github.com/a/b",
        "http://github.com/a/b", "https://moi:secret@github.com/a/b", "https://github.com:8443/a/b",
        "https://127.0.0.1/a", "https://192.168.1.10/depot", "https://[::1]/a", "https://2130706433/a", "https://localhost/a",
        "https://mon-mac.local/a", "https://mon-mac.tailnet.ts.net/a", "https://gіthub.com/a/b", "https://github.com/a b",
        "https://github.com/a/../../b", "https://example.org/--upload-pack=x", "pypi:", "pypi:../x", "pypi:nom --option", "pypi:-nom",
    ])
    func toutLeResteEstRefuse(texte: String) {
        #expect(throws: CibleDistante.Refus.self) { try CibleDistante(texte) }
    }

    @Test func rienDeCeQuiPasseNeDemandeDAccord() throws {
        // Ce qui est accepté à distance est exactement ce qui part à l'IA sans demander : jamais un élément du Mac.
        for texte in ["https://github.com/a/b", "pypi:requests", "https://pypi.org/project/requests/"] {
            #expect(!Confidentialite.accordRequis(cible: try CibleDistante(texte).cible))
        }
    }

    @Test func listeDuServeurLue() throws {
        let json = #"""
        {"worker":true,"audits":[
          {"id":"0123456789abcdef","target":"https://github.com/auteur/depot","state":"running","requestedAt":"2026-10-13T14:00:00Z","startedAt":"2026-10-13T14:00:05Z","step":"Règles automatiques (12 fichiers)…"},
          {"id":"fedcba9876543210","target":"pypi:requests","state":"done","requestedAt":"2026-10-13T13:00:00Z","endedAt":"2026-10-13T13:02:00Z","verdict":"rien_de_grave"}]}
        """#
        let liste = try Distant.decoder(ListeDistante.self, Data(json.utf8))
        #expect(liste.relaisActif && liste.audits.count == 2)
        #expect(liste.audits[0].etat == .enCours && liste.audits[0].actif && liste.audits[0].nomCourt == "auteur/depot")
        #expect(liste.audits[1].verdict == .rienDeGrave && liste.audits[1].nomCourt == "requests" && liste.audits[1].fin != nil)
        // Un audit terminé est relu avec son rapport.
        let rapport = String(decoding: try Self.rapport("https://github.com/auteur/depot").json(), as: UTF8.self)
        let complet = #"{"id":"0123456789abcdef","target":"https://github.com/auteur/depot","state":"done","requestedAt":"2026-10-13T14:00:00Z","verdict":"risque","report":\#(rapport)}"#
        #expect(try Distant.decoder(AuditDistant.self, Data(complet.utf8)).rapport?.resume == "Résumé d'essai.")
    }

    // MARK: - Relais du Mac

    static func rapport(_ cible: String) -> Rapport {
        Rapport(cible: Cible(type: .depot, source: cible), date: Date(timeIntervalSince1970: 1_800_000_000), verdict: .risque, resume: "Résumé d'essai.",
                constats: [], reseau: Reseau(), nonAnalyse: [], couches: Couches(regles: true, ia: false), fichiersAnalyses: 3)
    }

    /// Faux serveur : note les appels, et répond `annuler` aux points d'avancement.
    final class Serveur: @unchecked Sendable {
        private let verrou = NSLock()
        private var recus: [(chemin: String, corps: String)] = []
        var annuler = false
        var appels: [(chemin: String, corps: String)] { verrou.withLock { recus } }

        func repondre(_ chemin: String, _ corps: Data) -> (code: Int, corps: Data)? {
            verrou.withLock { recus.append((chemin, String(decoding: corps, as: UTF8.self))) }
            if chemin.hasSuffix("/progress") { return (200, Data(#"{"cancel":\#(annuler)}"#.utf8)) }
            if chemin == "api/cerbere/next" { return (200, Data(#"{"id":"0123456789abcdef","target":"https://github.com/auteur/depot"}"#.utf8)) }
            return (204, Data())
        }
    }

    final class Compteur: @unchecked Sendable {
        private let verrou = NSLock()
        private var cibles: [String] = []
        var vues: [String] { verrou.withLock { cibles } }
        func noter(_ cible: String) { verrou.withLock { cibles.append(cible) } }
    }

    @Test func demandeAuditeeEtRapportRendu() throws {
        let serveur = Serveur(), audits = Compteur(), ranges = Compteur()
        let relais = RelaisDistant(envoyer: serveur.repondre, auditer: { cible, _, suivi in
            audits.noter(cible)
            suivi(Avancement(.regles, "Règles automatiques (3 fichiers)…"))
            return Self.rapport(cible)
        }, ranger: { _, cible in ranges.noter(cible) })
        let demande = try #require(relais.suivante(redemarrage: true) ?? nil)
        #expect(serveur.appels[0].corps == #"{"restart":true}"#)
        // Le lien est ramené à l'adresse du dépôt avant l'audit, même si le serveur en a laissé passer plus.
        relais.traiter(.init(id: demande.id, cible: "https://github.com/auteur/depot/tree/main"))
        #expect(audits.vues == ["https://github.com/auteur/depot"] && ranges.vues == audits.vues)
        let appels = serveur.appels
        #expect(appels.contains { $0.chemin == "api/cerbere/audits/0123456789abcdef/progress" && $0.corps.contains("Règles automatiques") })
        let rendu = try #require(appels.last)
        #expect(rendu.chemin == "api/cerbere/audits/0123456789abcdef/result")
        let lu = try JSONDecoder().decode([String: AuditRendu].self, from: Data(rendu.corps.utf8))
        #expect(lu["report"]?.verdict == "risque")
    }

    struct AuditRendu: Decodable { var verdict: String }

    @Test(arguments: ["/Users/moi/Documents/projet", "~/Desktop", "file:///Users/moi/secret", "https://192.168.1.10/depot", "http://github.com/a/b", "pypi:../../etc"])
    func rienDuMacNiDuReseauLocalNEstAudite(cible: String) throws {
        let serveur = Serveur(), audits = Compteur()
        let relais = RelaisDistant(envoyer: serveur.repondre, auditer: { c, _, _ in
            audits.noter(c)
            return Self.rapport(c)
        })
        relais.traiter(.init(id: "0123456789abcdef", cible: cible))
        #expect(audits.vues.isEmpty)
        let rendu = try #require(serveur.appels.last)
        #expect(rendu.chemin.hasSuffix("/result") && rendu.corps.contains("refusée") && !rendu.corps.contains("report"))
    }

    @Test func annulationDemandeeDepuisLIPhone() throws {
        let serveur = Serveur()
        serveur.annuler = true
        let ranges = Compteur()
        let relais = RelaisDistant(envoyer: serveur.repondre, auditer: { cible, annulation, suivi in
            suivi(Avancement(.lecture, "Lecture par IA : lot 1 sur 6…"))
            // Le point d'avancement a rapporté l'annulation : l'audit s'arrête comme dans l'app Mac.
            try annulation.verifier()
            return Self.rapport(cible)
        }, ranger: { _, cible in ranges.noter(cible) })
        relais.traiter(.init(id: "0123456789abcdef", cible: "pypi:requests"))
        let rendu = try #require(serveur.appels.last)
        #expect(rendu.corps.contains("Audit annulé") && ranges.vues.isEmpty)
    }

    @Test func erreurVenueDuSiteDistantBorneeEtSurUneLigne() throws {
        let serveur = Serveur()
        let relais = RelaisDistant(envoyer: serveur.repondre, auditer: { _, _, _ in
            throw ErreurCerbere.cloneEchoue("fatal: dépôt introuvable\n\u{202E}remote: " + String(repeating: "x", count: 900))
        })
        relais.traiter(.init(id: "0123456789abcdef", cible: "https://github.com/auteur/absent"))
        let lu = try JSONDecoder().decode([String: String].self, from: Data(try #require(serveur.appels.last).corps.utf8))
        let texte = try #require(lu["error"])
        #expect(texte.count <= 200 && !texte.contains("\n") && !texte.contains("\u{202E}") && texte.hasPrefix("Récupération impossible"))
    }

    @Test func serveurArreteOuSansJeton() {
        let relais = RelaisDistant(envoyer: { _, _ in nil }, auditer: { c, _, _ in Self.rapport(c) })
        #expect(relais.suivante(redemarrage: true) == .none)
        let rien = RelaisDistant(envoyer: { _, _ in (204, Data()) }, auditer: { c, _, _ in Self.rapport(c) })
        #expect(rien.suivante(redemarrage: false) == .some(nil))
    }
}

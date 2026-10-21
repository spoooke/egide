import Foundation
import Testing
@testable import CerbereKit

/// Phase 6 : règles YARA. Les fichiers piégés sont fabriqués ici (textes cachés, programme glissé dans une image) ;
/// rien n'est lancé. Demande `yara` (Homebrew) : sans lui, ces essais sont sautés.
@Suite(.enabled(if: Yara.outil != nil))
struct YaraTests {
    @Test func reglesCompilentSansAvertissement() throws {
        let dossier = FileManager.default.temporaryDirectory.appending(path: "cerbere-yara-essai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dossier) }
        try Data(Yara.texte.utf8).write(to: dossier.appending(path: "regles.yar"))
        let r = Outil.lancer(try #require(Yara.outil), ["--fail-on-warnings", dossier.appending(path: "regles.yar").path, dossier.path])
        #expect(r.code == 0, "\(r.erreur)")
    }

    @Test func base64RemisEnClairQuelQueSoitLAlignement() {
        let texte = "powershell -nop -w hidden -c iex"
        for prefixe in ["", "a", "ab", "abc"] {
            let encode = Data((prefixe + texte).utf8).base64EncodedString()
            let d = Data([0, 1, 2]) + Data(encode.utf8) + Data([0, 0])
            // yara signale le début du motif, quelque part dans le bloc.
            #expect(Yara.devoilerBase64(d, 3 + encode.count / 2)?.contains(texte) == true, "\(prefixe)")
        }
        let large = Data(Data(texte.utf16.flatMap { [UInt8($0), 0] }).base64EncodedString().utf8.flatMap { [$0, 0] })
        #expect(Yara.devoilerBase64(large, 10)?.contains(texte) == true)
    }

    @Test func adressesVraisemblables() {
        for bonne in ["https://collecte.example.invalid/envoi", "http://203.0.113.9:8080/x", "http://evil.ru", "https://a.b.co.uk/?q=1", "http://c2.example.com\"x"] {
            #expect(Yara.adresseVraisemblable(bonne), "\(bonne)")
        }
        for mauvaise in ["http://www.years beforeThis", "http:// &nbsp;driver", "http://localhost", "https://abc.thisisnotatld/x"] {
            #expect(!Yara.adresseVraisemblable(mauvaise), "\(mauvaise)")
        }
    }

    @Test func fichiersPieges() throws {
        let jeu = try Jeu([
            "config/pool.conf": "# réglages\nurl = stratum+tcp://pool.example.invalid:3333\n",
            "LISEZMOI.md": "Exemple de texte à repérer : your files have been encrypted.\n",
        ])
        defer { jeu.nettoyer() }
        let adresse = Array("https://collecte.example.invalid/envoi".utf8).map { $0 ^ 0x5A }
        let commande = Array(Data("powershell -nop -w hidden -c iex".utf8).base64EncodedString().utf8)
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 7, count: 40)
        try jeu.octets("photo.png", png + adresse + [0, 0] + commande + [0, 0] + [UInt8](Fabrique.pe()))
        try Fabrique.pe().write(to: jeu.dossier.appending(path: "outil.exe"))
        let navigateur = ["Login Data", "Local State", "Cookies", "Google/Chrome", "nkbihfbeogaeaoehlefnkodbefgpgknn", "exodus.wallet"]
        try jeu.octets("voleur.bin", [0, 1, 2] + navigateur.flatMap { s in s.utf16.flatMap { [UInt8($0), 0] } + [0, 0] })

        // Ce qui ne doit rien donner (vu dans Firefox et Electron) : mots isolés d'un navigateur, « http:// » suivi d'un texte.
        try jeu.octets("moteur.bin", [0, 1] + Array("bitcoin\0.onion\0Decrypt\0".utf8) + Array("http:// &nbsp;texte ordinaire".utf8).map { $0 ^ 0x03 } + [0x03]
                         + Array(("http://www.w3.org/shortcut icon\" href=\"\" " + String(repeating: "<div class=\"css\">texte</div>", count: 12)).utf8).map { $0 ^ 0x03 } + [0x03])

        let r = try jeu.rapport()
        #expect(r.couches.yara == true)
        #expect(!r.a("yara.rancon", dans: "moteur.bin") && !r.a("yara.xor", dans: "moteur.bin [caché]"))
        let xor = try #require(r.constats("yara.xor").first)
        #expect(xor.fichier == "photo.png [caché]" && xor.extrait.contains("https://collecte.example.invalid/envoi") && xor.extrait.contains("clé 0x5a"))
        // Le domaine remis en clair rejoint la liste de ce que le code peut contacter.
        #expect(r.reseau.domaines.contains { $0.nom == "collecte.example.invalid" && $0.fichiers.contains("photo.png [caché]") })
        let b64 = try #require(r.constats("yara.base64").first)
        #expect(b64.fichier == "photo.png [caché]" && b64.extrait.contains("powershell -nop -w hidden -c iex"))
        let cache = try #require(r.constats("yara.programme-cache").first)
        #expect(cache.fichier == "photo.png" && cache.gravite == .elevee && cache.extrait.contains("octet 0x"))
        // Un programme Windows n'est pas « caché » dans lui-même.
        #expect(!r.a("yara.programme-cache", dans: "outil.exe"))
        let mineur = try #require(r.constats("yara.mineur").first)
        #expect(mineur.fichier == "config/pool.conf" && mineur.lignes == [2, 2] && mineur.gravite == .elevee)
        // Dans la documentation, un cran plus bas.
        #expect(r.constats("yara.rancon").first?.gravite == .moyenne)
        #expect(r.a("yara.navigateurs", dans: "voleur.bin") && r.a("yara.portefeuilles", dans: "voleur.bin"))
    }

    @Test func sansYaraLeRapportLeDit() throws {
        let jeu = try Jeu(["a.txt": "bonjour\n"])
        defer { jeu.nettoyer() }
        var r = try jeu.rapport()
        #expect(r.couches.yara == true && !r.resume.contains("YARA non appliquées"))
        // Rapport d'avant la phase 6 : le champ manque, il se relit quand même.
        r.couches.yara = nil
        let ancien = try JSONDecoder().decode(Couches.self, from: Data(#"{"regles":true,"ia":false}"#.utf8))
        #expect(ancien.yara == nil)
    }
}

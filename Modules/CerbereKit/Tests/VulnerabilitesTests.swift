import Foundation
import Testing
@testable import CerbereKit

/// Phase 6 : dépendances lues dans les fichiers de verrouillage, comparées à une fausse base OSV qui garde les
/// requêtes reçues. Rien ne sort du Mac.
struct VulnerabilitesTests {
    static let verrous: [String: String] = [
        "web/package-lock.json": """
        {
          "name": "projet-prive",
          "lockfileVersion": 3,
          "packages": {
            "": { "name": "projet-prive", "version": "1.0.0" },
            "node_modules/lodash": { "version": "4.17.15" },
            "node_modules/@scope/outil": { "version": "2.0.0" },
            "node_modules/a/node_modules/lodash": { "version": "4.17.21" },
            "node_modules/lien-local": { "version": "0.0.1", "link": true }
          }
        }
        """,
        "web/yarn.lock": "# yarn\n\n\"@babel/core@^7.0.0\", \"@babel/core@^7.1.0\":\n  version \"7.1.2\"\n  resolved \"https://registry.example.invalid/x\"\n\nleft-pad@^1.0.0:\n  version \"1.3.0\"\n",
        "requirements.txt": "# outils\nrequests==2.19.0\nflask>=2.0\nDjango[argon2] == 3.2.1 ; python_version > '3'\n",
        "poetry.lock": "[[package]]\nname = \"jinja2\"\nversion = \"2.10\"\n\n[[package]]\nname = \"urllib3\"\nversion = \"1.24.1\"\n",
        "uv.lock": "[[package]]\nname = \"moi-meme\"\nversion = \"0.1.0\"\nsource = { editable = \".\" }\n\n[[package]]\nname = \"idna\"\nversion = \"2.7\"\nsource = { registry = \"https://pypi.org/simple\" }\n",
        "Cargo.lock": "[[package]]\nname = \"mon-crate\"\nversion = \"0.1.0\"\n\n[[package]]\nname = \"smallvec\"\nversion = \"1.6.0\"\nsource = \"registry+https://github.com/rust-lang/crates.io-index\"\n",
        "go.mod": "module example.invalid/projet\n\ngo 1.22\n\nrequire (\n\tgolang.org/x/net v0.7.0 // indirect\n\tgithub.com/gin-gonic/gin v1.6.0\n)\n\nrequire github.com/pkg/errors v0.9.1\n",
        "Gemfile.lock": "GEM\n  remote: https://rubygems.org/\n  specs:\n    nokogiri (1.10.4-x86_64-darwin)\n      mini_portile2 (~> 2.4.0)\n    rack (2.0.6)\n\nPLATFORMS\n  ruby\n",
        "composer.lock": "{\n  \"packages\": [\n    { \"name\": \"guzzlehttp/guzzle\", \"version\": \"v6.5.0\" },\n    { \"name\": \"moi/dev\", \"version\": \"dev-main\" }\n  ]\n}\n",
        "App/Package.resolved": "{\n  \"pins\": [\n    { \"identity\": \"swift-nio\", \"location\": \"https://github.com/apple/swift-nio.git\", \"state\": { \"version\": \"2.40.0\" } },\n    { \"identity\": \"branche\", \"location\": \"https://github.com/x/y.git\", \"state\": { \"branch\": \"main\" } }\n  ]\n}\n",
    ]

    @Test func dependancesRelevees() throws {
        let jeu = try Jeu(Self.verrous)
        defer { jeu.nettoyer() }
        let q = try Quarantaine.copier(dossier: jeu.dossier, racine: jeu.racine)
        defer { try? FileManager.default.removeItem(at: q.dossier) }
        let deps = Inventaire(quarantaine: q).dependances
        func a(_ e: String, _ n: String, _ v: String) -> Bool { deps.contains { $0.ecosysteme == e && $0.nom == n && $0.version == v } }
        #expect(a("npm", "lodash", "4.17.15") && a("npm", "lodash", "4.17.21") && a("npm", "@scope/outil", "2.0.0"))
        #expect(!deps.contains { $0.nom == "projet-prive" || $0.nom == "lien-local" })
        #expect(a("npm", "@babel/core", "7.1.2") && a("npm", "left-pad", "1.3.0"))
        #expect(a("PyPI", "requests", "2.19.0") && a("PyPI", "Django", "3.2.1") && !deps.contains { $0.nom == "flask" })
        #expect(a("PyPI", "jinja2", "2.10") && a("PyPI", "urllib3", "1.24.1") && a("PyPI", "idna", "2.7") && !deps.contains { $0.nom == "moi-meme" })
        #expect(a("crates.io", "smallvec", "1.6.0") && !deps.contains { $0.nom == "mon-crate" })
        #expect(a("Go", "golang.org/x/net", "0.7.0") && a("Go", "github.com/gin-gonic/gin", "1.6.0") && a("Go", "github.com/pkg/errors", "0.9.1"))
        #expect(!deps.contains { $0.nom == "example.invalid/projet" })
        #expect(a("RubyGems", "nokogiri", "1.10.4") && a("RubyGems", "rack", "2.0.6") && !deps.contains { $0.nom == "mini_portile2" })
        #expect(a("Packagist", "guzzlehttp/guzzle", "6.5.0") && !deps.contains { $0.nom == "moi/dev" })
        #expect(a("SwiftURL", "github.com/apple/swift-nio", "2.40.0") && !deps.contains { $0.nom.contains("x/y") })
        let requests = try #require(deps.first { $0.nom == "requests" })
        #expect(requests.fichier == "requirements.txt" && requests.ligne == 2)
        #expect(deps.first { $0.nom == "lodash" && $0.version == "4.17.15" }?.ligne == 6)
    }

    /// Fausse base : `lodash 4.17.15` a deux failles, `event-stream 3.3.6` est malveillant.
    final class FausseBase: @unchecked Sendable {
        private let verrou = NSLock()
        private(set) var requetes: [URLRequest] = []

        func repondre(_ r: URLRequest) -> (code: Int, donnees: Data) {
            verrou.lock()
            requetes.append(r)
            verrou.unlock()
            let chemin = r.url?.path() ?? ""
            if chemin == "/v1/querybatch" {
                let corps = (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any]
                let questions = corps?["queries"] as? [[String: Any]] ?? []
                let reponses: [[String: Any]] = questions.map { q in
                    let nom = (q["package"] as? [String: String])?["name"] ?? "", version = q["version"] as? String ?? ""
                    switch (nom, version) {
                    case ("lodash", "4.17.15"): return ["vulns": [["id": "GHSA-p6mc-m468-83gw"], ["id": "GHSA-35jh-r3h4-6jhm"]]]
                    case ("event-stream", "3.3.6"): return ["vulns": [["id": "MAL-2022-1"]]]
                    case ("flatmap-stream", "0.1.1"): return ["vulns": [["id": "GHSA-9x64-5r7x-2q53"]]]
                    default: return [:]
                    }
                }
                return (200, try! JSONSerialization.data(withJSONObject: ["results": reponses]))
            }
            let fiches: [String: [String: Any]] = [
                "/v1/vulns/GHSA-p6mc-m468-83gw": ["id": "GHSA-p6mc-m468-83gw", "summary": "Prototype Pollution in lodash <script>", "aliases": ["CVE-2020-8203"],
                                                  "database_specific": ["severity": "HIGH"],
                                                  "affected": [["ranges": [["events": [["introduced": "0"], ["fixed": "4.17.19"]]]]]]],
                "/v1/vulns/GHSA-35jh-r3h4-6jhm": ["id": "GHSA-35jh-r3h4-6jhm", "summary": "Command Injection in lodash", "aliases": ["CVE-2021-23337"],
                                                  "database_specific": ["severity": "HIGH"],
                                                  "affected": [["ranges": [["events": [["introduced": "0"], ["fixed": "4.17.21"]]]]]]],
                "/v1/vulns/GHSA-9x64-5r7x-2q53": ["id": "GHSA-9x64-5r7x-2q53", "summary": "Malicious code in flatmap-stream", "database_specific": ["severity": "CRITICAL"]],
                "/v1/vulns/MAL-2022-1": ["id": "MAL-2022-1", "summary": "Malicious code in event-stream (npm) https://example.invalid/x"],
            ]
            guard let f = fiches[chemin] else { return (404, Data()) }
            return (200, try! JSONSerialization.data(withJSONObject: f))
        }
    }

    @Test func fausseBaseOSV() throws {
        let jeu = try Jeu([
            "package-lock.json": """
            {
              "lockfileVersion": 3,
              "packages": {
                "": { "name": "projet-secret" },
                "node_modules/lodash": { "version": "4.17.15" },
                "node_modules/event-stream": { "version": "3.3.6" },
                "node_modules/left-pad": { "version": "1.3.0" },
                "node_modules/flatmap-stream": { "version": "0.1.1" }
              }
            }
            """,
        ])
        defer { jeu.nettoyer() }
        let base = FausseBase()
        let osv = Vulnerabilites(transport: { r, _ in base.repondre(r) })
        let r = try Audit.auditer(jeu.dossier.path, racine: jeu.racine, enLigne: EnLigne(vulnerabilites: osv))
        #expect(r.couches.vulnerabilites == true)
        let mal = try #require(r.constats("dep.malveillant").first)
        #expect(mal.gravite == .critique && mal.statut == .confirme && mal.fichier == "package-lock.json" && mal.lignes == [6, 6])
        #expect(mal.extrait.contains("MAL-2022-1") && !mal.extrait.contains("://"))
        #expect(r.verdict == .nePasInstaller)
        let faille = try #require(r.constats("dep.faille").first)
        #expect(faille.gravite == .moyenne && faille.statut == .confirme && faille.categorie == .dependances)
        #expect(faille.extrait.contains("CVE-2020-8203") && faille.extrait.contains("corrigé en 4.17.21") && !faille.extrait.contains("<"))
        #expect(r.constats("dep.faille").count == 1)
        #expect(r.resume.contains("4 dépendances comparées à la base OSV (npm 4), 3 touchées"))
        // Avis GitHub de logiciel malveillant, sans identifiant MAL- : reconnu à son intitulé.
        #expect(r.constats("dep.malveillant").contains { $0.titre.contains("flatmap-stream") })

        // Ce qui est parti : un seul domaine, et rien d'autre que écosystème, nom et version.
        #expect(base.requetes.allSatisfy { $0.url?.host() == "api.osv.dev" && $0.url?.scheme == "https" })
        let envoi = try #require(base.requetes.first { $0.httpMethod == "POST" })
        let texte = String(decoding: envoi.httpBody ?? Data(), as: UTF8.self)
        #expect(!texte.contains("projet-secret") && !texte.contains("package-lock") && !texte.contains(jeu.dossier.path))
        let questions = try #require(((try JSONSerialization.jsonObject(with: envoi.httpBody ?? Data())) as? [String: Any])?["queries"] as? [[String: Any]])
        #expect(questions.count == 4 && questions.allSatisfy { Set($0.keys) == ["package", "version"] && Set(($0["package"] as? [String: String] ?? [:]).keys) == ["ecosystem", "name"] })
        #expect(base.requetes.filter { $0.httpMethod != "POST" }.count == 4)
    }

    @Test func sansAccordRienNePart() throws {
        let jeu = try Jeu(["requirements.txt": "requests==2.19.0\n"])
        defer { jeu.nettoyer() }
        let r = try Audit.auditer(jeu.dossier.path, racine: jeu.racine)
        #expect(r.couches.vulnerabilites == nil && !r.resume.contains("OSV"))
    }

    @Test func baseInjoignableOuAutreDomaine() throws {
        let jeu = try Jeu(["requirements.txt": "requests==2.19.0\n"])
        defer { jeu.nettoyer() }
        let panne = Vulnerabilites(transport: { _, _ in throw Vulnerabilites.Erreur.reseau("essai") })
        let r = try Audit.auditer(jeu.dossier.path, racine: jeu.racine, enLigne: EnLigne(vulnerabilites: panne))
        #expect(r.couches.vulnerabilites == nil && r.nonAnalyse.contains { $0.raison.contains("non vérifiées") })
        #expect(throws: Vulnerabilites.Erreur.self) {
            try Vulnerabilites.envoyer(URLRequest(url: URL(string: "https://example.invalid/v1/querybatch")!), annulation: nil)
        }
        #expect(Vulnerabilites.avant("4.17.9", "4.17.21") && !Vulnerabilites.avant("2.0", "1.9.9"))
    }

    /// Une faille qui « permet d'exécuter du code malveillant » reste une faille (cas réel : uv 0.7.8, PYSEC-2026-2295).
    @Test func failleDecriteCommeMalveillanteNEstPasUnPaquetMalveillant() {
        func fiche(_ id: String, _ resume: String) -> Vulnerabilites.Fiche {
            Vulnerabilites.Fiche(id: id, resume: resume, alias: [], gravite: "", corrigee: [])
        }
        #expect(!fiche("PYSEC-2026-2295", "A flaw was found in uv. This vulnerability allows an attacker to execute malicious code during package resolution").malveillant)
        #expect(fiche("GHSA-9x64-5r7x-2q53", "Malicious code in flatmap-stream").malveillant)
        #expect(fiche("MAL-2022-1", "anything").malveillant)
    }
}

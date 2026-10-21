import Foundation

/// Dépendance à version exacte, lue dans un fichier de verrouillage du code audité (rien n'est installé ni résolu).
public struct Dependance: Hashable, Sendable {
    /// Écosystème au sens de la base OSV : npm, PyPI, crates.io, Go, RubyGems, Packagist, SwiftURL.
    public let ecosysteme: String
    public let nom: String
    public let version: String
    public let fichier: String
    /// Ligne où elle est déclarée (0 si inconnue).
    public let ligne: Int
}

/// Relevé des dépendances épinglées. Seuls les fichiers qui donnent une version exacte sont lus : une plage
/// (« ^1.2 ») ne dit pas ce qui serait installé.
enum Dependances {
    static let max = 3000
    static let tailleMax = 40_000_000

    static func relever(_ fichiers: [Fichier], base: String, source: String) -> [Dependance] {
        var trouvees: [Dependance] = []
        // Le paquet PyPI audité lui-même : « pypi:nom version (archives) ».
        let morceaux = source.split(separator: " ")
        if source.hasPrefix("pypi:"), morceaux.count >= 2 {
            trouvees.append(Dependance(ecosysteme: "PyPI", nom: String(morceaux[0].dropFirst(5)), version: String(morceaux[1]), fichier: "(paquet audité)", ligne: 0))
        }
        for f in fichiers where !f.fiche && f.nature == .texte && f.taille <= tailleMax {
            guard let lecteur = lecteur(pour: f.nom.lowercased()) else { continue }
            // Un gros fichier de verrouillage n'est pas gardé ligne à ligne par l'inventaire : il est relu ici.
            var lignes = f.lignes
            if lignes.isEmpty, let d = try? Data(contentsOf: URL(fileURLWithPath: base + "/" + f.chemin), options: .mappedIfSafe) {
                lignes = String(decoding: d, as: UTF8.self).components(separatedBy: "\n")
            }
            trouvees += lecteur(lignes.joined(separator: "\n"), lignes, f)
            if trouvees.count >= max { break }
        }
        var vues = Set<String>(), uniques: [Dependance] = []
        for d in trouvees where !d.nom.isEmpty && !d.version.isEmpty && d.nom.count <= 214 && d.version.count <= 64
            && vues.insert("\(d.ecosysteme)\u{0}\(d.nom.lowercased())\u{0}\(d.version)").inserted {
            uniques.append(d)
        }
        return Array(uniques.prefix(max))
    }

    typealias Lecteur = (String, [String], Fichier) -> [Dependance]

    static func lecteur(pour nom: String) -> Lecteur? {
        switch nom {
        case "package-lock.json", "npm-shrinkwrap.json": return npmVerrou
        case "yarn.lock": return yarn
        case "pnpm-lock.yaml": return pnpm
        case "poetry.lock", "uv.lock", "pdm.lock": return tomlPaquets("PyPI")
        case "cargo.lock": return tomlPaquets("crates.io")
        case "pipfile.lock": return pipfile
        case "go.mod": return gomod
        case "gemfile.lock": return gemfile
        case "composer.lock": return composer
        case "package.resolved": return swiftpm
        default:
            if (nom.hasPrefix("requirements") && nom.hasSuffix(".txt")) || nom == "constraints.txt" { return requirements }
            return nil
        }
    }

    /// Première ligne (numérotée à partir de 1) qui contient ce texte.
    private static func ligne(_ lignes: [String], _ texte: String, depuis: Int = 0) -> Int {
        guard depuis < lignes.count else { return 0 }
        return (lignes[depuis...].firstIndex { $0.contains(texte) }).map { $0 + 1 } ?? 0
    }

    private static func json(_ texte: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(texte.utf8))) as? [String: Any]
    }

    // MARK: Lecteurs

    static func npmVerrou(_ texte: String, _ lignes: [String], _ f: Fichier) -> [Dependance] {
        guard let racine = json(texte) else { return [] }
        var r: [Dependance] = []
        if let paquets = racine["packages"] as? [String: Any] {
            for (chemin, valeur) in paquets {
                guard let p = valeur as? [String: Any], let version = p["version"] as? String, p["link"] as? Bool != true,
                      let debut = chemin.range(of: "node_modules/", options: .backwards) else { continue }
                let nom = (p["name"] as? String) ?? String(chemin[debut.upperBound...])
                r.append(Dependance(ecosysteme: "npm", nom: nom, version: version, fichier: f.chemin, ligne: ligne(lignes, "\"\(chemin)\"")))
            }
        } else if let deps = racine["dependencies"] as? [String: Any] {
            // Ancien format : dépendances imbriquées.
            func parcourir(_ deps: [String: Any]) {
                for (nom, valeur) in deps {
                    guard let p = valeur as? [String: Any] else { continue }
                    if let version = p["version"] as? String, !version.contains(":") {
                        r.append(Dependance(ecosysteme: "npm", nom: nom, version: version, fichier: f.chemin, ligne: ligne(lignes, "\"\(nom)\": {")))
                    }
                    if let sous = p["dependencies"] as? [String: Any] { parcourir(sous) }
                }
            }
            parcourir(deps)
        }
        return r.sorted { ($0.ligne, $0.nom) < ($1.ligne, $1.nom) }
    }

    static func yarn(_ texte: String, _ lignes: [String], _ f: Fichier) -> [Dependance] {
        var r: [Dependance] = [], noms: [String] = [], debut = 0
        for (i, l) in lignes.enumerated() {
            if !l.hasPrefix(" "), l.hasSuffix(":"), !l.hasPrefix("#") {
                noms = l.dropLast().split(separator: ",").compactMap { morceau in
                    let s = morceau.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                    // « @scope/nom@^1.0 » ou « nom@npm:^1.0 » : le nom va jusqu'au dernier @ qui n'est pas le premier caractère.
                    guard let a = s.dropFirst().lastIndex(of: "@") else { return nil }
                    return String(s[..<a])
                }
                debut = i + 1
            } else if let v = l.range(of: #"^\s+version:?\s+"?([^"\s]+)"?"#, options: .regularExpression), let nom = noms.first {
                let version = l[v].split(whereSeparator: { $0 == " " || $0 == "\"" || $0 == ":" }).last.map(String.init) ?? ""
                r.append(Dependance(ecosysteme: "npm", nom: nom, version: version, fichier: f.chemin, ligne: debut))
                noms = []
            }
        }
        return r
    }

    static func pnpm(_ texte: String, _ lignes: [String], _ f: Fichier) -> [Dependance] {
        var r: [Dependance] = []
        let motif = try! NSRegularExpression(pattern: #"^\s{2}['"]?/?(@?[^@\s'"/(][^@\s'"(]*)@(\d[^\s:'"()]*)['"(:]"#)
        for (i, l) in lignes.enumerated() {
            guard let m = motif.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)), let n = Range(m.range(at: 1), in: l), let v = Range(m.range(at: 2), in: l) else { continue }
            r.append(Dependance(ecosysteme: "npm", nom: String(l[n]), version: String(l[v]), fichier: f.chemin, ligne: i + 1))
        }
        return r
    }

    static func requirements(_ texte: String, _ lignes: [String], _ f: Fichier) -> [Dependance] {
        var r: [Dependance] = []
        let motif = try! NSRegularExpression(pattern: #"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s*(\[[^\]]*\])?\s*===?\s*([A-Za-z0-9.+!_-]+)\s*(;|#|\\|$)"#)
        for (i, l) in lignes.enumerated() {
            guard let m = motif.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)), let n = Range(m.range(at: 1), in: l), let v = Range(m.range(at: 3), in: l) else { continue }
            r.append(Dependance(ecosysteme: "PyPI", nom: String(l[n]), version: String(l[v]), fichier: f.chemin, ligne: i + 1))
        }
        return r
    }

    /// `[[package]]` puis `name = "…"`, `version = "…"` (Cargo.lock, poetry.lock, uv.lock).
    /// Pour Cargo, un paquet sans `source` est un morceau du projet lui-même, pas une dépendance publiée.
    static func tomlPaquets(_ ecosysteme: String) -> Lecteur {
        { _, lignes, f in
            var r: [Dependance] = [], nom = "", version = "", source = false, local = false, debut = 0, dedans = false
            func ranger() {
                if dedans, !nom.isEmpty, !version.isEmpty, !local, ecosysteme != "crates.io" || source {
                    r.append(Dependance(ecosysteme: ecosysteme, nom: nom, version: version, fichier: f.chemin, ligne: debut))
                }
                nom = ""; version = ""; source = false; local = false
            }
            func valeur(_ l: String) -> String { l.split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) } ?? "" }
            for (i, l) in lignes.enumerated() {
                let t = l.trimmingCharacters(in: .whitespaces)
                if t == "[[package]]" { ranger(); dedans = true; debut = i + 1; continue }
                if t.hasPrefix("[") { ranger(); dedans = false; continue }
                guard dedans else { continue }
                if t.hasPrefix("name =") || t.hasPrefix("name=") { nom = valeur(t) }
                else if t.hasPrefix("version =") || t.hasPrefix("version=") { version = valeur(t) }
                else if t.hasPrefix("source =") || t.hasPrefix("source=") {
                    source = valeur(t).hasPrefix("registry+")
                    // uv.lock : le projet lui-même (« editable », « virtual ») ou un dossier local, pas un paquet publié.
                    local = ["editable", "virtual", "directory", "path ="].contains { t.contains($0) }
                }
            }
            ranger()
            return r
        }
    }

    static func pipfile(_ texte: String, _ lignes: [String], _ f: Fichier) -> [Dependance] {
        guard let racine = json(texte) else { return [] }
        var r: [Dependance] = []
        for groupe in ["default", "develop"] {
            for (nom, valeur) in racine[groupe] as? [String: Any] ?? [:] {
                guard let version = (valeur as? [String: Any])?["version"] as? String, version.hasPrefix("==") else { continue }
                r.append(Dependance(ecosysteme: "PyPI", nom: nom, version: String(version.dropFirst(2)), fichier: f.chemin, ligne: ligne(lignes, "\"\(nom)\": {")))
            }
        }
        return r.sorted { $0.ligne < $1.ligne }
    }

    static func gomod(_ texte: String, _ lignes: [String], _ f: Fichier) -> [Dependance] {
        var r: [Dependance] = [], bloc = false
        for (i, l) in lignes.enumerated() {
            let t = l.split(separator: "//").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if t.hasPrefix("require (") { bloc = true; continue }
            if bloc && t == ")" { bloc = false; continue }
            let mots = t.split(separator: " ").map(String.init)
            let paire: [String]? = bloc ? mots : (mots.first == "require" ? Array(mots.dropFirst()) : nil)
            guard let p = paire, p.count == 2, p[1].hasPrefix("v") else { continue }
            // La base OSV range les versions de Go sans le « v » ni « +incompatible ».
            let version = String(p[1].dropFirst()).replacingOccurrences(of: "+incompatible", with: "")
            r.append(Dependance(ecosysteme: "Go", nom: p[0], version: version, fichier: f.chemin, ligne: i + 1))
        }
        return r
    }

    static func gemfile(_ texte: String, _ lignes: [String], _ f: Fichier) -> [Dependance] {
        var r: [Dependance] = [], gem = false
        let motif = try! NSRegularExpression(pattern: #"^ {4}([A-Za-z0-9._-]+) \(([0-9][^)\s]*)\)$"#)
        for (i, l) in lignes.enumerated() {
            if !l.hasPrefix(" ") { gem = l == "GEM"; continue }
            guard gem, let m = motif.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)), let n = Range(m.range(at: 1), in: l), let v = Range(m.range(at: 2), in: l) else { continue }
            // « 1.15.4-arm64-darwin » : la plateforme ne fait pas partie de la version.
            let version = String(l[v]).split(separator: "-").first.map(String.init) ?? ""
            r.append(Dependance(ecosysteme: "RubyGems", nom: String(l[n]), version: version, fichier: f.chemin, ligne: i + 1))
        }
        return r
    }

    static func composer(_ texte: String, _ lignes: [String], _ f: Fichier) -> [Dependance] {
        guard let racine = json(texte) else { return [] }
        var r: [Dependance] = []
        for groupe in ["packages", "packages-dev"] {
            for p in racine[groupe] as? [[String: Any]] ?? [] {
                guard let nom = p["name"] as? String, var version = p["version"] as? String, !version.hasPrefix("dev-") else { continue }
                if version.hasPrefix("v") { version.removeFirst() }
                r.append(Dependance(ecosysteme: "Packagist", nom: nom, version: version, fichier: f.chemin, ligne: ligne(lignes, "\"name\": \"\(nom)\"")))
            }
        }
        return r
    }

    static func swiftpm(_ texte: String, _ lignes: [String], _ f: Fichier) -> [Dependance] {
        guard let racine = json(texte) else { return [] }
        let pins = (racine["pins"] as? [[String: Any]]) ?? ((racine["object"] as? [String: Any])?["pins"] as? [[String: Any]]) ?? []
        var r: [Dependance] = []
        for p in pins {
            guard let lien = (p["location"] as? String) ?? (p["repositoryURL"] as? String),
                  let version = (p["state"] as? [String: Any])?["version"] as? String, let url = URL(string: lien), let hote = url.host() else { continue }
            // OSV nomme un paquet Swift par l'adresse de son dépôt, sans « https:// » ni « .git ».
            var chemin = url.path()
            if chemin.hasSuffix(".git") { chemin.removeLast(4) }
            r.append(Dependance(ecosysteme: "SwiftURL", nom: hote + chemin, version: version, fichier: f.chemin, ligne: ligne(lignes, lien)))
        }
        return r
    }
}

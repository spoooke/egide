import Foundation

/// Scripts lancés à l'installation et dépendances : lecture des fichiers de paquets (jamais d'installation).
enum Installation {
    private static let dangereux = try! NSRegularExpression(
        pattern: #"\b(curl|wget|base64|eval|powershell|osascript|chmod|sudo)\b|https?://|\bnode\s+(-e|--eval)\b|\bpython3?\s+-c\b|\|\s*(ba|z)?sh\b|\brm\s+-rf\b|\.(sh|py|ps1)\b"#,
        options: [.caseInsensitive])
    private static let anodins = try! NSRegularExpression(
        pattern: #"^\s*(husky(\s+install)?|patch-package|node-gyp(\s+rebuild)?|ngcc|electron-builder\s+install-app-deps|prisma\s+generate|tsc(\s+-b)?|(npm|yarn|pnpm)\s+run\s+build|is-ci\s*\|\|\s*husky(\s+install)?|simple-git-hooks|lefthook\s+install|opencollective(-postinstall)?(\s*\|\|\s*true)?)\s*$"#,
        options: [.caseInsensitive])

    private static func trouve(_ motif: NSRegularExpression, _ s: String) -> Bool {
        motif.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// Ligne (à partir de 1) où apparaît un texte, pour citer l'endroit d'une clé JSON.
    private static func ligne(de texte: String, dans f: Fichier) -> [Int] {
        guard let i = f.lignes.firstIndex(where: { $0.contains(texte) }) else { return [] }
        return [i + 1, i + 1]
    }

    private static func constat(_ regle: String, _ categorie: Categorie, _ gravite: Gravite, _ titre: String, _ f: Fichier,
                                _ lignes: [Int], _ extrait: String, _ explication: String, statut: Statut = .suspect) -> Constat {
        Constat(id: "", gravite: gravite, statut: statut, categorie: categorie, titre: titre, fichier: f.chemin, lignes: lignes,
                extrait: String(extrait.prefix(240)), explication: explication, origine: .regle, regle: regle)
    }

    static func analyser(_ fichiers: [Fichier]) -> [Constat] {
        let dossiersVerrouilles = Set(fichiers.filter {
            ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "npm-shrinkwrap.json", "poetry.lock", "uv.lock", "pipfile.lock"]
                .contains($0.nom.lowercased())
        }.map { ($0.chemin as NSString).deletingLastPathComponent })
        var constats: [Constat] = []
        for f in fichiers {
            let nom = f.nom.lowercased()
            let dossier = (f.chemin as NSString).deletingLastPathComponent
            let composants = f.chemin.lowercased().split(separator: "/")
            if nom == "package.json" { constats += npm(f, verrouille: dossiersVerrouilles.contains(dossier)) }
            else if nom == "setup.py" { constats += setupPy(f) }
            else if nom.hasPrefix("requirements") && nom.hasSuffix(".txt") { constats += requirements(f, verrouille: dossiersVerrouilles.contains(dossier)) }
            else if nom == "build.rs" {
                constats.append(constat("inst.build-rs", .installation, .info, "Script de compilation Rust", f, [], "",
                                        "build.rs s'exécute sur la machine pendant `cargo build` : à relire avant de compiler.", statut: .confirme))
            } else if ["preinstall", "postinstall", "preflight", "postflight"].contains(nom) && composants.contains(where: { $0 == "scripts" || $0.hasSuffix(".pkg") }) {
                constats.append(constat("inst.pkg", .installation, .moyenne, "Script d'un paquet d'installation", f, [], f.lignes.first ?? "",
                                        "Ce script est lancé par l'installateur, souvent avec les droits d'administrateur."))
            } else if composants.dropLast().contains(where: { [".husky", ".githooks"].contains($0) }) && f.nature == .texte && !nom.hasPrefix(".") && nom != "husky.sh" {
                constats.append(constat("inst.hooks", .installation, .faible, "Hook git livré avec le dépôt", f, [], f.lignes.first ?? "",
                                        "Une fois activé (souvent par un script d'installation), ce script tourne à chaque commit ou récupération."))
            } else if f.suffixe == "pbxproj" {
                for (i, ligne) in f.lignes.enumerated() where ligne.contains("shellScript = ") && trouve(dangereux, ligne) {
                    constats.append(constat("inst.xcode", .installation, .moyenne, "Script lancé à la compilation (Xcode)", f, [i + 1, i + 1], ligne.trimmingCharacters(in: .whitespaces),
                                            "Cette phase de script s'exécute à chaque compilation du projet et contient un téléchargement ou une commande sensible."))
                }
            }
        }
        return constats
    }

    // MARK: npm

    static func npm(_ f: Fichier, verrouille: Bool) -> [Constat] {
        guard let donnees = f.lignes.joined(separator: "\n").data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: donnees) as? [String: Any] else { return [] }
        var constats: [Constat] = []
        let scripts = json["scripts"] as? [String: Any] ?? [:]
        for cle in ["preinstall", "install", "postinstall", "prepare", "preuninstall", "postuninstall"] {
            guard let commande = scripts[cle] as? String else { continue }
            let lieu = ligne(de: "\"\(cle)\"", dans: f)
            if trouve(anodins, commande) {
                constats.append(constat("inst.npm", .installation, .info, "Script d'installation npm (outil courant)", f, lieu, "\(cle): \(commande)",
                                        "Lancé automatiquement par `npm install` ; commande d'un outil connu."))
            } else if trouve(dangereux, commande) {
                constats.append(constat("inst.npm", .installation, .elevee, "Script d'installation npm sensible", f, lieu, "\(cle): \(commande)",
                                        "Lancé automatiquement par `npm install`, avant toute relecture, et il télécharge, décode ou lance un autre programme."))
            } else {
                constats.append(constat("inst.npm", .installation, cle == "prepare" ? .faible : .moyenne, "Script lancé automatiquement à l'installation (npm)", f, lieu, "\(cle): \(commande)",
                                        "Lancé automatiquement par `npm install` : à relire, ainsi que le fichier qu'il appelle."))
            }
        }
        var libres: [String] = []
        for section in ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"] {
            for (paquet, valeur) in (json[section] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                let version = (valeur as? String ?? "").trimmingCharacters(in: .whitespaces)
                let lieu = ligne(de: "\"\(paquet)\"", dans: f)
                if version.range(of: #"^(git(\+\w+)?:|https?:|github:|gitlab:|bitbucket:|[\w.-]+/[\w.-]+(#.*)?$)"#, options: .regularExpression) != nil {
                    constats.append(constat("dep.hors-registre", .dependances, .moyenne, "Dépendance prise hors du registre", f, lieu, "\(paquet): \(version)",
                                            "Ce paquet vient d'une adresse directe : son contenu n'est ni vérifié ni figé par le registre npm."))
                } else if ["", "*", "latest", "x", "next"].contains(version.lowercased()) || version.hasPrefix(">") {
                    constats.append(constat("dep.non-bornee", .dependances, .faible, "Dépendance sans version bornée", f, lieu, "\(paquet): \(version.isEmpty ? "(vide)" : version)",
                                            "N'importe quelle version future sera installée, y compris une version piégée."))
                } else if version.hasPrefix("^") || version.hasPrefix("~") {
                    libres.append(paquet)
                }
                if let proche = Sosies.proche(de: paquet, parmi: Sosies.npm) {
                    constats.append(constat("dep.sosie", .dependances, .moyenne, "Nom proche d'un paquet connu", f, lieu, "\(paquet) (connu : \(proche))",
                                            "Un nom presque identique à celui d'un paquet très utilisé est le procédé habituel des paquets piégés."))
                }
            }
        }
        if !libres.isEmpty, !verrouille {
            constats.append(constat("dep.non-epinglee", .dependances, .info, "Dépendances non épinglées, sans fichier de verrouillage", f, [], libres.prefix(12).joined(separator: ", "),
                                    "\(libres.count) dépendances acceptent des versions futures et aucun fichier de verrouillage ne fige celles qui seront installées.", statut: .confirme))
        }
        return constats
    }

    // MARK: Python

    private static let codeDansSetup = try! NSRegularExpression(
        pattern: #"\bos\.(system|popen)\(|\bsubprocess\.|\burlopen\(|\brequests\.(get|post)\(|\bsocket\.|\bbase64\.|\b(exec|eval)\s*\(|\b__import__\("#)

    static func setupPy(_ f: Fichier) -> [Constat] {
        var constats: [Constat] = []
        for (i, ligne) in f.lignes.enumerated() {
            if ligne.contains("cmdclass") {
                constats.append(constat("inst.setup-cmdclass", .installation, .moyenne, "Commande d'installation personnalisée (Python)", f, [i + 1, i + 1], ligne.trimmingCharacters(in: .whitespaces),
                                        "setup.py remplace une étape de `pip install` par son propre code : à relire."))
            } else if trouve(codeDansSetup, ligne), constats.filter({ $0.regle == "inst.setup-code" }).count < 3 {
                constats.append(constat("inst.setup-code", .installation, .elevee, "setup.py exécute du code à l'installation", f, [i + 1, i + 1], ligne.trimmingCharacters(in: .whitespaces),
                                        "Ce code tourne pendant `pip install` : commande système, réseau ou code décodé n'ont rien à faire dans un setup.py ordinaire."))
            }
        }
        return constats
    }

    static func requirements(_ f: Fichier, verrouille: Bool) -> [Constat] {
        var constats: [Constat] = [], libres: [String] = []
        for (i, brute) in f.lignes.enumerated() {
            let ligne = (brute.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
            guard !ligne.isEmpty else { continue }
            let lieu = [i + 1, i + 1]
            if ligne.range(of: #"^(-i|--index-url|--extra-index-url|--find-links|-f)\b"#, options: .regularExpression) != nil {
                if !ligne.contains("pypi.org") && !ligne.contains("download.pytorch.org") {
                    constats.append(constat("dep.index", .dependances, .elevee, "Autre source de paquets Python", f, lieu, ligne,
                                            "Les paquets seront cherchés ailleurs que sur PyPI : un paquet du même nom peut y remplacer le vrai."))
                }
            } else if ligne.range(of: #"(^|\s|@)(git\+|https?://)"#, options: .regularExpression) != nil {
                constats.append(constat("dep.hors-registre", .dependances, .moyenne, "Dépendance prise hors du registre", f, lieu, ligne,
                                        "Ce paquet vient d'une adresse directe : son contenu n'est ni vérifié ni figé par PyPI."))
            } else if !ligne.hasPrefix("-") {
                let paquet = String(ligne.prefix { $0.isLetter || $0.isNumber || "-_.".contains($0) })
                if !ligne.contains("==") && !ligne.contains("===") { libres.append(paquet) }
                if let proche = Sosies.proche(de: paquet, parmi: Sosies.pypi) {
                    constats.append(constat("dep.sosie", .dependances, .moyenne, "Nom proche d'un paquet connu", f, lieu, "\(paquet) (connu : \(proche))",
                                            "Un nom presque identique à celui d'un paquet très utilisé est le procédé habituel des paquets piégés."))
                }
            }
        }
        if !libres.isEmpty, !verrouille {
            constats.append(constat("dep.non-epinglee", .dependances, .info, "Dépendances non épinglées", f, [], libres.prefix(12).joined(separator: ", "),
                                    "\(libres.count) dépendances n'ont pas de version exacte : la version installée dépendra du jour.", statut: .confirme))
        }
        return constats
    }
}

/// Noms de paquets presque identiques à un paquet très utilisé.
enum Sosies {
    static let npm: Set<String> = [
        "react", "react-dom", "lodash", "express", "axios", "chalk", "commander", "request", "moment", "debug", "async", "bluebird",
        "underscore", "webpack", "typescript", "eslint", "prettier", "mocha", "babel-core", "angular", "jquery", "nodemon", "dotenv",
        "yargs", "minimist", "rimraf", "mkdirp", "colors", "inquirer", "socket.io", "mongoose", "body-parser", "jsonwebtoken", "bcrypt",
        "node-fetch", "cross-env", "electron", "puppeteer", "discord.js", "ethers", "tailwindcss", "rollup", "esbuild", "redux",
        "semver", "cheerio", "sharp", "passport", "nodemailer", "mysql", "redis", "sequelize", "vue-router", "react-router", "ts-node",
        "fs-extra", "uuid", "web3", "next", "vite", "jest", "glob", "cors",
    ]
    static let pypi: Set<String> = [
        "requests", "urllib3", "numpy", "pandas", "setuptools", "python-dateutil", "certifi", "boto3", "botocore", "pyyaml",
        "cryptography", "flask", "django", "pytest", "scipy", "matplotlib", "pillow", "beautifulsoup4", "selenium", "colorama",
        "click", "jinja2", "sqlalchemy", "tensorflow", "torch", "scikit-learn", "opencv-python", "pydantic", "fastapi", "aiohttp",
        "httpx", "paramiko", "pycryptodome", "psutil", "tqdm", "lxml", "openai", "anthropic", "discord.py", "telethon", "web3",
        "pyinstaller", "virtualenv", "wheel", "rich", "idna", "six",
    ]
    /// Paquets légitimes dont le nom ressemble à un autre.
    static let legitimes: Set<String> = ["preact", "color", "ether", "clack", "redis", "redux", "jest", "vitest", "nuxt", "nest", "vue", "globby", "core-js", "flash", "torchx", "httpx", "httpie"]

    static func proche(de nom: String, parmi connus: Set<String>) -> String? {
        let n = nom.lowercased()
        guard n.count >= 4, !connus.contains(n), !legitimes.contains(n), !n.hasPrefix("@") else { return nil }
        // Même nom à la ponctuation près (python_dateutil, lodash.js…) : sur npm c'est un autre paquet.
        let nu = n.filter { $0.isLetter || $0.isNumber }
        for connu in connus.sorted() where abs(connu.count - n.count) <= 2 && connu.count >= 4 {
            if connu.filter({ $0.isLetter || $0.isNumber }) == nu { return connus == pypi ? nil : connu }
            let d = distance(Array(n), Array(connu))
            if d == 1 || (d == 2 && connu.count >= 9) { return connu }
        }
        return nil
    }

    /// Distance d'édition, une inversion de deux lettres voisines comptant pour un.
    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cout = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cout)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[a.count][b.count]
    }
}

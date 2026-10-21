import Foundation

/// Un fichier de la quarantaine, tel que les règles le voient.
public struct Fichier: Sendable {
    public enum Nature: String, Sendable { case texte, executable, archive, document, binaire }

    public let chemin: String
    public let taille: Int
    public let nature: Nature
    /// Format reconnu à la signature (« Mach-O », « zip »…), quand ce n'est pas du texte.
    public let format: String?
    public let etaitExecutable: Bool
    /// Lignes du fichier (texte seulement, vide sinon ou si le fichier est trop gros).
    public let lignes: [String]
    /// Fiche écrite par Cerbère à partir d'un binaire, d'une signature ou d'un document (pas un fichier de la cible).
    public var fiche = false

    /// Fiche lisible tirée d'un fichier qui ne l'est pas : les règles et la lecture par IA la lisent comme un texte.
    static func fiche(_ chemin: String, _ lignes: [String]) -> Fichier {
        Fichier(chemin: chemin, taille: lignes.reduce(0) { $0 + $1.utf8.count + 1 }, nature: .texte, format: nil, etaitExecutable: false, lignes: lignes, fiche: true)
    }

    public var nom: String { (chemin as NSString).lastPathComponent }
    public var suffixe: String { (chemin as NSString).pathExtension.lowercased() }

    /// Documentation ou exemple : un motif y est une mention, pas forcément du code lancé.
    public var estDocumentation: Bool {
        ["md", "markdown", "rst", "txt", "adoc", "html", "htm"].contains(suffixe)
            // PKG-INFO et METADATA : la fiche d'un paquet Python, qui recopie le README.
            || ["license", "copying", "changelog", "authors", "notice", "pkg-info", "metadata"].contains(nom.lowercased())
    }

    /// Script de commandes (shell, PowerShell, recette de construction) : une ligne y est exécutée telle quelle.
    public var estScript: Bool {
        ["sh", "bash", "zsh", "ksh", "fish", "command", "ps1", "bat", "cmd", "mk"].contains(suffixe)
            || ["dockerfile", "makefile", "justfile", "preinstall", "postinstall"].contains(nom.lowercased())
            || (lignes.first.map { $0.hasPrefix("#!") && $0.range(of: #"\b(ba|z|k|da)?sh\b"#, options: .regularExpression) != nil } ?? false)
    }

    /// Fichiers générés où hachages et longues lignes sont normaux.
    public var estGenere: Bool {
        let n = nom.lowercased()
        return n.hasSuffix(".lock") || n.hasSuffix("-lock.json") || n.hasSuffix(".min.js") || n.hasSuffix(".min.css")
            || n.hasSuffix(".map") || n.hasSuffix(".sum") || n == "pnpm-lock.yaml" || n == "package.resolved"
            || ["svg", "pbxproj", "ipynb", "pem", "crt", "cer", "pub", "asc", "sig", "snap", "resolved"].contains(suffixe)
            // Liste des fichiers scellés par la signature d'une app : des chemins et des empreintes.
            || n == "coderesources"
    }
}

public struct Inventaire: Sendable {
    public var fichiers: [Fichier] = []
    public var constats: [Constat] = []
    public var nonAnalyse: [NonAnalyse] = []
    /// Empreintes à comparer à une base de réputation : le fichier audité, puis le programme principal de chaque app.
    public var empreintes: [EmpreinteNommee] = []
    /// Les règles YARA ont été appliquées (yara installé et sans erreur).
    public var yara = false
    /// Dépendances à version exacte (fichiers de verrouillage), pour la base OSV.
    public var dependances: [Dependance] = []

    /// Au-delà, un fichier texte n'est pas lu ligne à ligne.
    static let tailleTexteMax = 2_000_000

    static let suffixesAnodins: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "ico", "icns", "bmp", "tiff", "heic", "pdf", "svg", "txt", "md", "json", "xml",
        "yml", "yaml", "css", "html", "htm", "csv", "ttf", "otf", "woff", "woff2", "mp3", "mp4", "mov", "wav", "m4a",
    ]
    /// Ressources compilées d'une app et pièces d'un paquet : binaires attendus, sans code à lire.
    static let ressources: Set<String> = ["car", "nib", "storyboardc", "mom", "omo", "metallib", "bom", "aiff", "caf", "ttc", "dat", "db", "sqlite", "pak", "asar", "lproj", "strings", "icc", "cur"]
    static let nomsDeRessources: Set<String> = ["coderesources", "pkginfo", "bom", "payload", ".ds_store"]

    /// Signatures de formats (premiers octets).
    static func format(_ d: Data) -> (Fichier.Nature, String)? {
        func debut(_ octets: [UInt8], decalage: Int = 0) -> Bool {
            d.count >= decalage + octets.count && Array(d[d.startIndex + decalage ..< d.startIndex + decalage + octets.count]) == octets
        }
        let machO: [[UInt8]] = [[0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE], [0xFE, 0xED, 0xFA, 0xCF], [0xFE, 0xED, 0xFA, 0xCE],
                                [0xCA, 0xFE, 0xBA, 0xBE], [0xCA, 0xFE, 0xBA, 0xBF]]
        if machO.contains(where: { debut($0) }) {
            // CAFEBABE est aussi l'en-tête des classes Java.
            return (.executable, debut([0xCA, 0xFE, 0xBA, 0xBE]) && d.count > 7 && d[d.startIndex + 7] > 20 ? "classe Java" : "Mach-O")
        }
        if debut([0x7F, 0x45, 0x4C, 0x46]) { return (.executable, "ELF") }
        if debut([0x4D, 0x5A]) { return (.executable, "exécutable Windows") }
        if debut([0x00, 0x61, 0x73, 0x6D]) { return (.executable, "WebAssembly") }
        if debut([0x64, 0x65, 0x78, 0x0A]) { return (.executable, "DEX Android") }
        if debut([0x50, 0x4B, 0x03, 0x04]) { return (.archive, "zip") }
        if debut([0x1F, 0x8B]) { return (.archive, "gzip") }
        if debut([0x42, 0x5A, 0x68]) { return (.archive, "bzip2") }
        if debut([0xFD, 0x37, 0x7A, 0x58, 0x5A]) { return (.archive, "xz") }
        if debut([0x37, 0x7A, 0xBC, 0xAF]) { return (.archive, "7z") }
        if debut([0x52, 0x61, 0x72, 0x21]) { return (.archive, "rar") }
        if debut([0x78, 0x61, 0x72, 0x21]) { return (.archive, "paquet xar/pkg") }
        if debut([0x75, 0x73, 0x74, 0x61, 0x72], decalage: 257) { return (.archive, "tar") }
        if debut(Array("%PDF-".utf8)) { return (.document, "PDF") }
        if debut([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) { return (.document, "document Office (OLE)") }
        if debut(Array("bplist0".utf8)) { return (.document, "plist binaire") }
        return nil
    }

    /// Inventaire de la quarantaine, puis lecture de ce qui n'est pas du texte : programmes compilés (`Binaires`),
    /// documents (`Documents`), réglages et apps (`Embarques`). Les fiches produites s'ajoutent aux fichiers texte.
    public init(quarantaine q: Quarantaine, annulation: Annulation? = nil) {
        nonAnalyse = q.ecartes
        let depot = (q.sorte ?? (q.empreinte == nil ? .depot : .fichier)) == .depot
        var documents: [(chemin: String, format: String)] = []
        let fm = FileManager.default
        let base = q.dossier.resolvingSymlinksInPath().path
        var chemins: [String] = []
        if let parcours = fm.enumerator(atPath: base) {
            for case let court as String in parcours {
                let relatif = Plateforme.relatif(court)
                var estDossier: ObjCBool = false
                if fm.fileExists(atPath: base + "/" + relatif, isDirectory: &estDossier), !estDossier.boolValue { chemins.append(relatif) }
            }
        }
        // Les liens d'un dossier local ne sont pas copiés : ils n'existent que dans le relevé d'origine.
        chemins = Array(Set(chemins).union(q.origines.filter { $0.value.lien != nil }.keys))
        for chemin in chemins.sorted() {
            let etat = q.origines[chemin]
            if let cible = etat?.lien {
                // Le lien n'est pas un fichier à lire : on le signale s'il sort du dépôt.
                // Le raccourci « Applications » d'une image disque : habituel.
                let sort = (cible.hasPrefix("/") || cible.hasPrefix("~") || cible.split(separator: "/").contains("..")) && !(cible == "/Applications" && !depot)
                // Les liens internes d'une app (versions de ses bibliothèques) sont sa structure normale : pas un constat.
                guard sort || depot else { continue }
                constats.append(Constat(
                    id: "", gravite: sort ? .moyenne : .info, statut: sort ? .suspect : .confirme, categorie: .autre,
                    titre: sort ? "Lien symbolique qui sort du dépôt" : "Lien symbolique",
                    fichier: chemin, lignes: [], extrait: "→ " + String(cible.prefix(200)),
                    explication: sort ? "Ce lien pointe hors du dépôt : un outil qui le suit lirait ou écraserait un fichier de la machine."
                        : "Lien interne au dépôt (non recréé dans la quarantaine).",
                    origine: .regle, regle: "inventaire.lien"))
                continue
            }
            let url = URL(fileURLWithPath: base + "/" + chemin)
            guard let donnees = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                nonAnalyse.append(NonAnalyse(fichier: chemin, raison: "illisible"))
                continue
            }
            let executable = etat?.executable ?? false
            let suffixe = (chemin as NSString).pathExtension.lowercased()
            if let (nature, format) = Self.format(donnees) {
                fichiers.append(Fichier(chemin: chemin, taille: donnees.count, nature: nature, format: format,
                                        etaitExecutable: executable, lignes: []))
                if nature == .document {
                    // Un PDF qui porte le nom d'un PDF : rien à dire ici, son contenu est lu plus bas.
                    documents.append((chemin, format))
                    if Self.suffixesAnodins.contains(suffixe), !(format == "PDF" && suffixe == "pdf") {
                        constats.append(Constat(
                            id: "", gravite: .moyenne, statut: .suspect, categorie: .obfuscation, titre: "Document déguisé en .\(suffixe)",
                            fichier: chemin, lignes: [], extrait: "\(format), \(donnees.count) octets",
                            explication: "Le contenu est un \(format) alors que le nom annonce autre chose.", origine: .regle, regle: "inventaire.document"))
                    }
                    continue
                }
                if nature == .archive, !fm.fileExists(atPath: base + "/" + chemin + "!"), !q.examen.nonAnalyse.contains(where: { $0.fichier == chemin }) {
                    nonAnalyse.append(NonAnalyse(fichier: chemin, raison: "\(format) : non ouvert"))
                }
                if nature == .executable {
                    let cache = Self.suffixesAnodins.contains(suffixe)
                    // Dans une app ou un paquet, un programme compilé est attendu : seul le déguisement est signalé.
                    guard cache || depot else { continue }
                    constats.append(Constat(
                        id: "", gravite: cache ? .elevee : .moyenne, statut: cache ? .confirme : .suspect, categorie: .obfuscation,
                        titre: cache ? "Exécutable déguisé en .\(suffixe)" : "Exécutable compilé livré dans le dépôt",
                        fichier: chemin, lignes: [], extrait: "\(format), \(donnees.count) octets",
                        explication: cache ? "Le contenu est un programme (\(format)) alors que le nom annonce un fichier anodin."
                            : "Un programme déjà compilé ne peut pas être relu comme du code source : son comportement est inconnu.",
                        origine: .regle, regle: cache ? "inventaire.deguise" : "inventaire.executable"))
                } else if nature == .archive, Self.suffixesAnodins.contains(suffixe) {
                    constats.append(Constat(
                        id: "", gravite: .moyenne, statut: .suspect, categorie: .obfuscation, titre: "Archive déguisée en .\(suffixe)",
                        fichier: chemin, lignes: [], extrait: "\(format), \(donnees.count) octets",
                        explication: "Le contenu est une archive (\(format)) alors que le nom annonce autre chose.",
                        origine: .regle, regle: "inventaire.archive"))
                }
                continue
            }
            // Texte en UTF-16 (marque d'ordre en tête) : lu comme un texte, sinon il échapperait aux règles.
            let utf16 = (donnees.starts(with: [0xFF, 0xFE]) || donnees.starts(with: [0xFE, 0xFF])) && donnees.count <= Self.tailleTexteMax
                ? String(data: donnees, encoding: .utf16) : nil
            // Du texte : pas d'octet nul dans le début du fichier.
            let estTexte = utf16 != nil || !donnees.prefix(8192).contains(0)
            guard estTexte else {
                fichiers.append(Fichier(chemin: chemin, taille: donnees.count, nature: .binaire, format: nil, etaitExecutable: executable, lignes: []))
                if !Self.suffixesAnodins.contains(suffixe), !Self.ressources.contains(suffixe), !Self.nomsDeRessources.contains((chemin as NSString).lastPathComponent.lowercased()) {
                    nonAnalyse.append(NonAnalyse(fichier: chemin, raison: "binaire de format inconnu"))
                }
                continue
            }
            guard donnees.count <= Self.tailleTexteMax else {
                fichiers.append(Fichier(chemin: chemin, taille: donnees.count, nature: .texte, format: nil, etaitExecutable: executable, lignes: []))
                nonAnalyse.append(NonAnalyse(fichier: chemin, raison: "texte de plus de 2 Mo"))
                continue
            }
            let texte = utf16 ?? String(decoding: donnees, as: UTF8.self)
            let lignes = texte.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
            fichiers.append(Fichier(chemin: chemin, taille: donnees.count, nature: .texte, format: nil, etaitExecutable: executable, lignes: lignes))
        }
        for sousModule in q.sousModules {
            nonAnalyse.append(NonAnalyse(fichier: sousModule, raison: "sous-module git : jamais récupéré, à auditer à part"))
        }

        // Ce qui n'est pas du texte est lu ici, puis versé dans l'inventaire sous forme de fiches et de constats.
        var examens = [q.examen]
        let embarques = Embarques.examiner(fichiers, base: base)
        examens.append(embarques.examen)
        if let empreinte = q.empreinte { empreintes.append(EmpreinteNommee(nom: (q.source as NSString).lastPathComponent, sha256: empreinte)) }
        empreintes += embarques.empreintes
        for (chemin, format) in documents where format != "plist binaire" {
            guard annulation?.demandee != true else { break }
            guard let donnees = try? Data(contentsOf: URL(fileURLWithPath: base + "/" + chemin), options: .mappedIfSafe) else { continue }
            examens.append(format == "PDF" ? Documents.pdf(donnees, chemin: chemin) : Documents.ole(donnees, chemin: chemin))
        }
        examens.append(Binaires.examiner(fichiers, base: base, annulation: annulation))
        let yara = Yara.examiner(fichiers, base: base, annulation: annulation)
        examens.append(yara.examen)
        self.yara = yara.applique
        dependances = Dependances.relever(fichiers, base: base, source: q.source)
        for examen in examens {
            fichiers += examen.fiches
            constats += examen.constats
            nonAnalyse += examen.nonAnalyse
        }
    }

    /// Fichiers texte lus ligne à ligne.
    public var textes: [Fichier] { fichiers.filter { $0.nature == .texte && !$0.lignes.isEmpty } }
}

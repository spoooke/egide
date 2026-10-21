import Foundation

public enum ErreurCerbere: Error, CustomStringConvertible, Equatable {
    case lienRefuse(String)
    case cloneEchoue(String)
    case dossierIntrouvable(String)
    case archiveRefusee(String)
    case telechargementRefuse(String)
    case annule

    public var description: String {
        switch self {
        case .lienRefuse(let raison): "Lien refusé : \(raison)"
        case .cloneEchoue(let detail): "Récupération impossible : \(detail)"
        case .dossierIntrouvable(let chemin): "Dossier introuvable : \(chemin)"
        case .archiveRefusee(let raison): "Archive refusée : \(raison)"
        case .telechargementRefuse(let raison): "Téléchargement refusé : \(raison)"
        case .annule: "Audit annulé"
        }
    }
}

/// Ce que git savait d'un fichier avant la mise en quarantaine (les droits sont ensuite retirés).
public struct EtatOrigine: Equatable, Sendable {
    public var executable = false
    /// Cible du lien symbolique, si c'en était un (jamais recréé dans la quarantaine).
    public var lien: String?
}

/// Copie à examiner : lecture seule, aucun fichier exécutable, aucun script lancé pour l'obtenir.
/// Le contenu est une donnée non fiable : on le lit, on ne le lance jamais.
public struct Quarantaine: Sendable {
    public let dossier: URL
    public let source: String
    public let commit: String?
    /// Empreinte SHA-256 de l'archive, quand la cible en est une.
    public var empreinte: String? = nil
    /// Chemin relatif → état d'origine (exécutables et liens symboliques seulement).
    public var origines: [String: EtatOrigine]
    /// Sous-modules déclarés (jamais récupérés).
    public let sousModules: [String]
    /// Fichiers laissés de côté à la copie, avec la raison.
    public var ecartes: [NonAnalyse]
    /// Ce que la cible est (dépôt, app, fichier) ; nil : déduit de la présence d'une empreinte.
    public var sorte: Cible.Sorte? = nil
    /// Ce qui a été relevé à l'ouverture, là où les liens étaient intacts (signatures, paquet, image disque).
    var examen = Examen()

    public static var racine: URL {
        Plateforme.caches.appending(path: "quarantaine")
    }

    /// Plafond d'une copie de dossier local : au-delà, le reste est noté « non analysé ».
    static let fichiersMax = 20_000

    // MARK: - Dépôt distant

    /// Seuls les liens https vers un hôte nommé sont acceptés ; pas d'identifiants dans le lien.
    public static func verifier(lien: String) throws -> URL {
        guard let url = URL(string: lien), let hote = url.host(), !hote.isEmpty else { throw ErreurCerbere.lienRefuse("adresse illisible") }
        guard url.scheme?.lowercased() == "https" else { throw ErreurCerbere.lienRefuse("seul https est accepté") }
        guard url.user == nil, url.password == nil else { throw ErreurCerbere.lienRefuse("identifiants dans le lien") }
        guard !lien.hasPrefix("-"), !lien.contains(where: \.isWhitespace) else { throw ErreurCerbere.lienRefuse("caractères interdits") }
        return url
    }

    public static func cloner(lien: String, racine: URL = racine, annulation: Annulation? = nil) throws -> Quarantaine {
        try cloner(adresse: verifier(lien: lien).absoluteString, source: lien, protocole: "https", racine: racine, annulation: annulation)
    }

    /// Clone sans hooks, sans filtres, sans sous-modules, sans LFS, sans la configuration git de la machine
    /// (recette prouvée en phase 0, voir docs/cerbere.md). Un seul protocole est autorisé. `adresse` n'est pas
    /// vérifiée ici : les essais passent par là avec un dépôt local fabriqué (protocole `file`).
    static func cloner(adresse: String, source: String, protocole: String, racine: URL, annulation: Annulation? = nil) throws -> Quarantaine {
        let dossier = try nouveauDossier(dans: racine)
        let environnement = Plateforme.environnementGit(maison: racine)
        let reglages = ["-c", "core.hooksPath=\(Plateforme.nul)", "-c", "core.fsmonitor=false", "-c", "core.symlinks=false",
                        "-c", "core.fileMode=false", "-c", "protocol.allow=never", "-c", "protocol.\(protocole).allow=always",
                        "-c", "submodule.recurse=false", "-c", "http.followRedirects=initial",
                        "-c", "credential.helper="]
        let clone = git(reglages + ["clone", "--quiet", "--depth", "1", "--no-tags", "--single-branch",
                                    "--no-recurse-submodules", "--template=", "--", adresse, Plateforme.cheminOutil(dossier.path)], environnement, annulation)
        guard clone.code == 0, annulation?.demandee != true else {
            Plateforme.supprimer(dossier)
            try annulation?.verifier()
            throw ErreurCerbere.cloneEchoue(String(clone.erreur.prefix(300)))
        }
        func dansLeClone(_ arguments: [String]) -> String {
            git(reglages + ["-C", Plateforme.cheminOutil(dossier.path)] + arguments, environnement).sortie
        }
        let commit = dansLeClone(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Droits d'origine : 100755 exécutable, 120000 lien symbolique, 160000 sous-module.
        var origines: [String: EtatOrigine] = [:]
        var sousModules: [String] = []
        for entree in dansLeClone(["ls-tree", "-r", "-z", "HEAD"]).split(separator: "\0") {
            guard let tab = entree.firstIndex(of: "\t") else { continue }
            let mode = entree.prefix(6), chemin = String(entree[entree.index(after: tab)...])
            switch mode {
            case "100755": origines[chemin] = EtatOrigine(executable: true)
            case "120000":
                // core.symlinks=false : le lien est un fichier texte qui contient sa cible.
                let cible = (try? String(contentsOf: dossier.appending(path: chemin), encoding: .utf8)) ?? "?"
                origines[chemin] = EtatOrigine(lien: cible)
            case "160000": sousModules.append(chemin)
            default: break
            }
        }
        try Plateforme.supprimer(dossier.appending(path: ".git"), exiger: true)
        try verrouiller(dossier)
        return Quarantaine(dossier: dossier, source: source, commit: commit.isEmpty ? nil : commit,
                           origines: origines, sousModules: sousModules, ecartes: [])
    }

    // MARK: - Dossier local

    /// Copie un dossier local : fichiers ordinaires seulement, liens symboliques notés et jamais suivis,
    /// dossier `.git` laissé de côté.
    /// `sous` : sous-dossier de la quarantaine où ranger la copie (le nom d'une app, pour que ses chemins se lisent).
    public static func copier(dossier source: URL, sous: String = "", racine: URL = racine, annulation: Annulation? = nil) throws -> Quarantaine {
        let dossier = try nouveauDossier(dans: racine)
        var origines: [String: EtatOrigine] = [:]
        var ecartes: [NonAnalyse] = []
        var copies = 0
        do {
            try copier(contenu: source, vers: dossier, prefixe: sous.isEmpty ? "" : sous + "/", origines: &origines, ecartes: &ecartes, copies: &copies, annulation: annulation)
        } catch {
            Plateforme.supprimer(dossier)
            throw error
        }
        try verrouiller(dossier)
        return Quarantaine(dossier: dossier, source: source.path, commit: nil, origines: origines, sousModules: [], ecartes: ecartes)
    }

    /// Cœur de la copie : fichiers ordinaires recopiés sous `prefixe`, liens notés, le reste écarté.
    static func copier(contenu source: URL, vers dossier: URL, prefixe: String, origines: inout [String: EtatOrigine],
                       ecartes: inout [NonAnalyse], copies: inout Int, annulation: Annulation? = nil) throws {
        let fm = FileManager.default
        var estDossier: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &estDossier), estDossier.boolValue else {
            throw ErreurCerbere.dossierIntrouvable(source.path)
        }
        // Chemins relatifs donnés par le parcours lui-même ; `attributesOfItem` ne suit pas les liens.
        guard let parcours = fm.enumerator(atPath: source.path) else { throw ErreurCerbere.dossierIntrouvable(source.path) }
        for case let court as String in parcours {
            if annulation?.demandee == true { throw ErreurCerbere.annule }
            let chemin = source.path + "/" + court, relatif = prefixe + Plateforme.relatif(court)
            let type = try fm.attributesOfItem(atPath: chemin)[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                origines[relatif] = EtatOrigine(lien: (try? fm.destinationOfSymbolicLink(atPath: chemin)) ?? "?")
            } else if type == .typeDirectory {
                if (relatif as NSString).lastPathComponent == ".git" { parcours.skipDescendants() }
                // Dossier illisible (volume monté, archive) : son contenu manquerait sans rien dire.
                else if !fm.isReadableFile(atPath: chemin) { ecartes.append(NonAnalyse(fichier: relatif, raison: "dossier illisible")) }
            } else if type == .typeRegular {
                guard copies < fichiersMax else {
                    ecartes.append(NonAnalyse(fichier: relatif, raison: "au-delà de \(fichiersMax) fichiers"))
                    continue
                }
                let cible = dossier.appending(path: relatif)
                try fm.createDirectory(at: cible.deletingLastPathComponent(), withIntermediateDirectories: true)
                do { try fm.copyItem(atPath: chemin, toPath: cible.path) } catch {
                    ecartes.append(NonAnalyse(fichier: relatif, raison: "illisible"))
                    continue
                }
                copies += 1
                if fm.isExecutableFile(atPath: chemin) { origines[relatif] = EtatOrigine(executable: true) }
            } else {
                ecartes.append(NonAnalyse(fichier: relatif, raison: "fichier spécial (ni fichier ni dossier)"))
            }
        }
    }

    // MARK: - Archive

    /// Au-delà, une archive n'est pas ouverte.
    static let archiveMax = 300_000_000

    /// Ouvre une ou plusieurs archives (tar, zip, wheel…) sans rien installer : extraction par `bsdtar` dans un
    /// dossier provisoire (qui refuse les chemins absolus, les `..` et l'écriture à travers un lien), puis copie
    /// de quarantaine habituelle. Chaque archive va dans le sous-dossier `nom`.
    public static func extraire(archives: [(nom: String, fichier: URL)], source: String, racine: URL = racine,
                                gatekeeper: Bool = false, annulation: Annulation? = nil) throws -> Quarantaine {
        let fm = FileManager.default
        let provisoire = try nouveauDossier(dans: racine)
        defer { Plateforme.supprimer(provisoire) }
        for archive in archives {
            let taille = (try? fm.attributesOfItem(atPath: archive.fichier.path)[.size] as? Int) ?? nil
            guard let taille, taille <= archiveMax else { throw ErreurCerbere.archiveRefusee("introuvable ou de plus de 300 Mo") }
            let cible = provisoire.appending(path: archive.nom)
            try fm.createDirectory(at: cible, withIntermediateDirectories: true)
            let extraction = Plateforme.extraction(archive.fichier.path, vers: cible.path)
            let resultat = lancer(extraction.outil, extraction.arguments, Plateforme.environnement, annulation)
            try annulation?.verifier()
            // bsdtar signale par un code d'erreur les entrées qu'il a refusées ; le reste est extrait et audité.
            guard resultat.code == 0 || (try? fm.contentsOfDirectory(atPath: cible.path).isEmpty) == false else {
                throw ErreurCerbere.archiveRefusee(String(resultat.erreur.prefix(300)))
            }
            // Dossiers sans droit de traversée : sinon la copie s'arrêterait dessus.
            if let parcours = fm.enumerator(atPath: cible.path) {
                for case let relatif as String in parcours {
                    let chemin = cible.path + "/" + relatif
                    if (try? fm.attributesOfItem(atPath: chemin)[.type] as? FileAttributeType) == .typeDirectory {
                        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: chemin)
                    }
                }
            }
        }
        // Les apps de l'archive sont examinées ici : leurs liens internes ne sont pas recopiés dans la quarantaine.
        var examen = Examen()
        Plateforme.examinerApps(dans: provisoire, fiable: false, gatekeeper: gatekeeper, annulation: annulation, dans: &examen)
        try annulation?.verifier()
        var q = try copier(dossier: provisoire, racine: racine, annulation: annulation)
        q = Quarantaine(dossier: q.dossier, source: source, commit: nil, empreinte: empreinte(archives[0].fichier),
                        origines: q.origines, sousModules: [], ecartes: q.ecartes, examen: examen)
        return q
    }

    static func empreinte(_ fichier: URL) -> String? {
        guard let donnees = try? Data(contentsOf: fichier, options: .mappedIfSafe) else { return nil }
        return Plateforme.sha256(donnees)
    }

    public func supprimer() {
        // Les dossiers sont déjà en 0700 : la suppression n'a pas besoin de rendre de droits.
        Plateforme.supprimer(dossier)
    }

    // MARK: - Outils

    static func nouveauDossier(dans racine: URL) throws -> URL {
        try Plateforme.preparer(racine: racine)
        let dossier = racine.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return dossier
    }

    /// Fichiers en lecture seule sans droit d'exécution (0400), dossiers réservés à l'utilisateur (0700).
    static func verrouiller(_ dossier: URL) throws {
        let fm = FileManager.default
        guard let parcours = fm.enumerator(at: dossier, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for case let url as URL in parcours {
            let valeurs = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if valeurs.isSymbolicLink == true {
                try fm.removeItem(at: url)   // ne devrait pas exister ; par sûreté
            } else {
                try fm.setAttributes([.posixPermissions: valeurs.isDirectory == true ? 0o700 : 0o400], ofItemAtPath: url.path)
            }
        }
    }

    private static func git(_ arguments: [String], _ environnement: [String: String], _ annulation: Annulation? = nil) -> (code: Int32, sortie: String, erreur: String) {
        lancer(Plateforme.git, arguments, environnement, annulation)
    }

    /// Lance un outil du système (git, bsdtar), jamais un fichier de la quarantaine.
    private static func lancer(_ outil: String, _ arguments: [String], _ environnement: [String: String],
                               _ annulation: Annulation? = nil) -> (code: Int32, sortie: String, erreur: String) {
        let processus = Process()
        processus.executableURL = URL(fileURLWithPath: outil)
        processus.arguments = arguments
        processus.environment = environnement
        processus.currentDirectoryURL = FileManager.default.temporaryDirectory
        processus.standardInput = FileHandle.nullDevice
        let sortie = Pipe(), erreur = Pipe()
        processus.standardOutput = sortie
        processus.standardError = erreur
        do { try processus.run() } catch { return (-1, "", "\(error)") }
        annulation?.suivre(processus)
        defer { annulation?.oublier(processus) }
        // Lire avant d'attendre : un tuyau plein bloquerait git.
        let s = sortie.fileHandleForReading.readDataToEndOfFile()
        let e = erreur.fileHandleForReading.readDataToEndOfFile()
        processus.waitUntilExit()
        return (processus.terminationStatus, String(decoding: s, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }
}

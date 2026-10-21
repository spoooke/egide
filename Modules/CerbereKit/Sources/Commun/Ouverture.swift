import Foundation

/// Ce qui est relevé à l'ouverture d'une cible, avant la copie de quarantaine (qui ne recrée pas les liens) :
/// fiches lisibles, constats, éléments laissés de côté.
struct Examen: Sendable {
    var fiches: [Fichier] = []
    var constats: [Constat] = []
    var nonAnalyse: [NonAnalyse] = []
}

/// Ouverture d'une app, d'une image disque, d'un paquet d'installation ou d'un fichier seul, et des conteneurs
/// rangés dedans. Rien n'est installé ni lancé. Ce qui dépend du système (signatures, images disque et paquets du
/// Mac) passe par `Plateforme`.
extension Quarantaine {
    public enum Nature: String, Sendable { case dossier, app, image, paquet, archive, fichier }

    static let suffixesApp: Set<String> = ["app", "appex", "framework", "bundle", "plugin", "xpc", "kext", "systemextension", "prefpane", "saver", "qlgenerator", "mdimporter", "component"]

    /// Ce qu'est un élément du Mac, d'après son contenu (les premiers et derniers octets), pas d'après son nom.
    /// nil s'il n'existe pas. Rien n'est ouvert.
    public static func nature(de chemin: String) -> Nature? {
        let fm = FileManager.default
        var estDossier: ObjCBool = false
        guard fm.fileExists(atPath: chemin, isDirectory: &estDossier) else { return nil }
        if estDossier.boolValue {
            let app = suffixesApp.contains((chemin as NSString).pathExtension.lowercased()) || fm.fileExists(atPath: chemin + "/Contents/Info.plist")
            return app ? .app : .dossier
        }
        return nature(fichier: URL(fileURLWithPath: chemin))
    }

    static func nature(fichier: URL) -> Nature {
        guard let lecture = try? FileHandle(forReadingFrom: fichier) else { return .fichier }
        defer { try? lecture.close() }
        let debut = (try? lecture.read(upToCount: 512)) ?? Data()
        if let fin = try? lecture.seekToEnd(), fin >= 512, (try? lecture.seek(toOffset: fin - 512)) != nil,
           (try? lecture.read(upToCount: 4)) == Data("koly".utf8) { return .image }
        guard let (nature, format) = Inventaire.format(debut), nature == .archive else { return .fichier }
        return format.hasPrefix("paquet") ? .paquet : .archive
    }

    /// Au-delà, un paquet ou une image n'est pas ouvert.
    static let conteneurMax = 4_000_000_000
    static let profondeurMax = 3
    static let imbriquesMax = 40

    /// Met en quarantaine un élément du Mac, quel qu'il soit.
    static func ouvrir(local: URL, gatekeeper: Bool = false, racine: URL = racine, annulation: Annulation? = nil) throws -> Quarantaine {
        guard let nature = nature(de: local.path) else { throw ErreurCerbere.dossierIntrouvable(local.path) }
        var q: Quarantaine
        switch nature {
        case .dossier: q = try copier(dossier: local, racine: racine, annulation: annulation)
        case .app:
            // La signature se vérifie sur l'app elle-même : la copie de quarantaine ne recrée pas ses liens internes.
            var examen = Examen()
            Plateforme.examinerApp(local, gatekeeper: gatekeeper, annulation: annulation, dans: &examen)
            try annulation?.verifier()
            q = try copier(dossier: local, sous: local.lastPathComponent, racine: racine, annulation: annulation)
            q.examen = examen
            q.sorte = .app
        case .archive:
            q = try extraire(archives: [("archive", local)], source: local.path, racine: racine, gatekeeper: gatekeeper, annulation: annulation)
        case .paquet, .image:
            let dossier = try nouveauDossier(dans: racine)
            var examen = Examen(), origines: [String: EtatOrigine] = [:], ecartes: [NonAnalyse] = [], copies = 0
            do {
                try avecContenu(de: local, nature: nature, nom: local.lastPathComponent, racine: racine, gatekeeper: gatekeeper, annulation: annulation, examen: &examen) { base, sous in
                    try copier(contenu: base, vers: dossier, prefixe: sous, origines: &origines, ecartes: &ecartes, copies: &copies, annulation: annulation)
                }
                try annulation?.verifier()
            } catch ErreurCerbere.annule {
                Plateforme.supprimer(dossier)
                throw ErreurCerbere.annule
            } catch {
                // Conteneur illisible (image chiffrée, paquet abîmé) : l'audit continue sur ce qu'on sait, et le dit.
                examen.nonAnalyse.append(NonAnalyse(fichier: local.lastPathComponent, raison: "non ouvert : \(error)"))
            }
            try verrouiller(dossier)
            q = Quarantaine(dossier: dossier, source: local.path, commit: nil, empreinte: empreinte(local), origines: origines, sousModules: [],
                            ecartes: ecartes, sorte: .app, examen: examen)
        case .fichier:
            let dossier = try nouveauDossier(dans: racine)
            let taille = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int) ?? nil
            guard let taille, taille <= conteneurMax else {
                Plateforme.supprimer(dossier)
                throw ErreurCerbere.archiveRefusee("fichier illisible ou de plus de 4 Go")
            }
            var examen = Examen()
            if let lecture = try? FileHandle(forReadingFrom: local), let debut = try? lecture.read(upToCount: 512), let format = Inventaire.format(debut)?.1 {
                try? lecture.close()
                Plateforme.examinerProgramme(local, format: format, gatekeeper: gatekeeper, annulation: annulation, dans: &examen)
            }
            try FileManager.default.copyItem(at: local, to: dossier.appending(path: local.lastPathComponent))
            try verrouiller(dossier)
            q = Quarantaine(dossier: dossier, source: local.path, commit: nil, empreinte: empreinte(local),
                            origines: FileManager.default.isExecutableFile(atPath: local.path) ? [local.lastPathComponent: EtatOrigine(executable: true)] : [:],
                            sousModules: [], ecartes: [], sorte: .fichier, examen: examen)
        }
        if q.sorte == nil, nature != .dossier { q.sorte = .fichier }
        return q
    }

    // MARK: - Conteneurs imbriqués

    /// Archives, paquets et images rangés dans la quarantaine : chacun est ouvert à côté, dans `<chemin>!/`,
    /// jusqu'à trois niveaux. Vaut pour toutes les cibles (un dépôt peut livrer une archive).
    mutating func ouvrirImbriques(racine: URL = Quarantaine.racine, gatekeeper: Bool = false, annulation: Annulation? = nil) throws {
        let fm = FileManager.default
        let dossier = dossier
        let base = dossier.resolvingSymlinksInPath().path
        // Copie de travail : la fermeture qui recopie ne doit pas toucher à `self` pendant qu'il est modifié.
        var examen = self.examen
        defer { self.examen = examen }
        func fichiers(sous prefixe: String) -> [String] {
            (fm.enumerator(atPath: base + (prefixe.isEmpty ? "" : "/" + prefixe))?.compactMap { $0 as? String } ?? [])
                .map { prefixe.isEmpty ? Plateforme.relatif($0) : prefixe + "/" + Plateforme.relatif($0) }
                .filter { var d: ObjCBool = false; return fm.fileExists(atPath: base + "/" + $0, isDirectory: &d) && !d.boolValue }
        }
        var attente = fichiers(sous: "").sorted(), ouverts = 0, copies = attente.count, change = false
        while !attente.isEmpty {
            try annulation?.verifier()
            let relatif = attente.removeFirst()
            let url = URL(fileURLWithPath: base + "/" + relatif)
            let nature = Quarantaine.nature(fichier: url)
            guard nature != .fichier else { continue }
            let taille = ((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil) ?? 0
            let profondeur = relatif.components(separatedBy: "!/").count - 1
            guard profondeur < Quarantaine.profondeurMax, ouverts < Quarantaine.imbriquesMax, taille <= Quarantaine.archiveMax, copies < Quarantaine.fichiersMax else {
                examen.nonAnalyse.append(NonAnalyse(fichier: relatif, raison: "conteneur non ouvert (trop profond, trop gros ou trop nombreux) : à auditer à part"))
                continue
            }
            ouverts += 1
            let sous = relatif + "!"
            var nouvellesOrigines: [String: EtatOrigine] = [:], nouveauxEcartes: [NonAnalyse] = []
            do {
                try Quarantaine.avecContenu(de: url, nature: nature, nom: relatif, racine: racine, gatekeeper: gatekeeper, annulation: annulation, examen: &examen) { contenu, prefixe in
                    try Quarantaine.copier(contenu: contenu, vers: dossier, prefixe: sous + "/" + prefixe, origines: &nouvellesOrigines, ecartes: &nouveauxEcartes,
                                           copies: &copies, annulation: annulation)
                }
                try annulation?.verifier()
                change = true
                origines.merge(nouvellesOrigines) { $1 }
                ecartes += nouveauxEcartes
                attente += fichiers(sous: sous).sorted()
            } catch ErreurCerbere.annule { throw ErreurCerbere.annule } catch {
                examen.nonAnalyse.append(NonAnalyse(fichier: relatif, raison: "non ouvert : \(error)"))
            }
        }
        if change { try Quarantaine.verrouiller(dossier) }
    }

    // MARK: - Ouverture d'un conteneur

    /// Ouvre un conteneur dans un dossier provisoire (ou le monte), relève ce qui doit l'être tant que les liens
    /// sont intacts, donne chaque dossier à recopier à `lire` (avec le préfixe sous lequel le ranger), puis referme.
    static func avecContenu(de fichier: URL, nature: Nature, nom: String, racine: URL, gatekeeper: Bool, annulation: Annulation?,
                            examen: inout Examen, _ lire: (URL, String) throws -> Void) throws {
        let provisoire = try nouveauDossier(dans: racine)
        defer { Plateforme.supprimer(provisoire) }
        let contenu = provisoire.appending(path: "contenu")
        switch nature {
        case .image, .paquet:
            try Plateforme.ouvrirConteneur(fichier, nature: nature, nom: nom, provisoire: provisoire, contenu: contenu, gatekeeper: gatekeeper,
                                           annulation: annulation, examen: &examen, lire)
        default:
            try extraire(fichier, vers: contenu, annulation: annulation)
            rendreTraversable(contenu)
            Plateforme.examinerApps(dans: contenu, prefixe: nom + "!/", fiable: false, gatekeeper: gatekeeper, annulation: annulation, dans: &examen)
            try lire(contenu, "")
        }
    }

    /// Extraction par bsdtar (qui refuse les chemins absolus, les `..` et l'écriture à travers un lien), avec un
    /// plafond de taille par fichier et de durée : une archive faite pour remplir le disque s'arrête là.
    static func extraire(_ archive: URL, vers cible: URL, annulation: Annulation?) throws {
        try FileManager.default.createDirectory(at: cible, withIntermediateDirectories: true)
        let extraction = Plateforme.extractionBornee(archive.path, vers: cible.path)
        let r = Outil.lancer(extraction.outil, extraction.arguments, annulation: annulation, delai: 180)
        try annulation?.verifier()
        guard !r.horsDelai else { throw ErreurCerbere.archiveRefusee("extraction trop longue") }
        guard r.code == 0 || (try? FileManager.default.contentsOfDirectory(atPath: cible.path).isEmpty) == false else {
            throw ErreurCerbere.archiveRefusee(String(r.erreur.prefix(200)))
        }
    }

    /// Dossiers sans droit de traversée : sinon la copie s'arrêterait dessus.
    static func rendreTraversable(_ dossier: URL) {
        let fm = FileManager.default
        guard let parcours = fm.enumerator(atPath: dossier.path) else { return }
        for case let court as String in parcours {
            let chemin = dossier.path + "/" + Plateforme.relatif(court)
            if (try? fm.attributesOfItem(atPath: chemin)[.type] as? FileAttributeType) == .typeDirectory {
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: chemin)
            }
        }
    }
}

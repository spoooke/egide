import Foundation

/// Empreinte à comparer à une base de réputation : le fichier audité, ou le programme principal d'une app.
public struct EmpreinteNommee: Sendable, Equatable {
    public var nom: String
    public var sha256: String
}

/// Ce qu'une app embarque et annonce : fiche d'identité (`Info.plist`), agents et démons de lancement, réglages
/// en format binaire rendus lisibles, et fichiers dont le type ou le nom est fait pour être lancé d'un double-clic.
enum Embarques {
    static let plistMax = 2_000_000

    /// Réglages (plist) lus en mémoire, sans rien lancer.
    static func plist(_ donnees: Data) -> Any? {
        guard donnees.count <= plistMax else { return nil }
        return try? PropertyListSerialization.propertyList(from: donnees, format: nil)
    }

    /// Un plist binaire, réécrit en texte pour les règles et la lecture par IA.
    static func enClair(_ objet: Any) -> [String]? {
        guard PropertyListSerialization.propertyList(objet, isValidFor: .xml),
              let xml = try? PropertyListSerialization.data(fromPropertyList: objet, format: .xml, options: 0) else { return nil }
        return String(decoding: xml, as: UTF8.self).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }

    private static func texte(_ valeur: Any?) -> String {
        switch valeur {
        case let liste as [Any]: liste.map { texte($0) }.joined(separator: " ")
        // Un booléen de plist est un NSNumber de type « c » (CoreFoundation n'existe pas sur Windows).
        case let n as NSNumber where String(cString: n.objCType) == "c": n.boolValue ? "oui" : "non"
        case let v?: "\(v)"
        case nil: ""
        }
    }

    private static let usages: [(String, String)] = [
        ("NSCameraUsageDescription", "caméra"), ("NSMicrophoneUsageDescription", "micro"), ("NSAppleEventsUsageDescription", "pilotage d'autres apps"),
        ("NSContactsUsageDescription", "contacts"), ("NSCalendarsUsageDescription", "calendriers"), ("NSLocationUsageDescription", "position"),
        ("NSPhotoLibraryUsageDescription", "photos"), ("NSDesktopFolderUsageDescription", "Bureau"), ("NSDocumentsFolderUsageDescription", "Documents"),
        ("NSDownloadsFolderUsageDescription", "Téléchargements"), ("NSSystemAdministrationUsageDescription", "administration du Mac"),
        ("NSBluetoothAlwaysUsageDescription", "Bluetooth"), ("NSLocalNetworkUsageDescription", "réseau local"), ("NSRemindersUsageDescription", "rappels"),
        ("NSScreenCaptureUsageDescription", "écran"), ("NSInputMonitoringUsageDescription", "clavier"), ("NSSpeechRecognitionUsageDescription", "reconnaissance vocale"),
    ]

    private static let lanceAuClic: [String: (Gravite, String)] = [
        "inetloc": (.moyenne, "raccourci Internet"), "fileloc": (.moyenne, "raccourci vers un fichier"), "terminal": (.moyenne, "réglages de Terminal avec commande"),
        "lnk": (.moyenne, "raccourci Windows"), "hta": (.moyenne, "application HTML Windows"), "scr": (.moyenne, "programme Windows"), "pif": (.moyenne, "programme Windows"),
        "jnlp": (.moyenne, "lanceur Java"), "command": (.faible, "script lancé dans Terminal"), "tool": (.faible, "script lancé dans Terminal"),
        "workflow": (.faible, "processus Automator"), "action": (.faible, "action Automator"), "scpt": (.faible, "script AppleScript"), "scptd": (.faible, "script AppleScript"),
        "jar": (.faible, "programme Java"), "vbs": (.faible, "script Windows"), "wsf": (.faible, "script Windows"), "shortcut": (.faible, "raccourci de l'app Raccourcis"),
    ]
    private static let doubleSuffixe = try! NSRegularExpression(
        pattern: #"\.(pdf|docx?|xlsx?|pptx?|jpe?g|png|gif|txt|mp[34]|mov|zip|csv)\.(app|command|exe|scr|pkg|dmg|terminal|sh|js|jar|lnk|hta|scpt|workflow|tool)$"#, options: [.caseInsensitive])

    /// Constats tirés des noms et des réglages ; fiches des plists binaires ; empreintes des programmes principaux.
    static func examiner(_ fichiers: [Fichier], base: String) -> (examen: Examen, empreintes: [EmpreinteNommee]) {
        var examen = Examen(), empreintes: [EmpreinteNommee] = []
        let parChemin = Dictionary(fichiers.map { ($0.chemin, $0) }, uniquingKeysWith: { a, _ in a })
        func constat(_ regle: String, _ gravite: Gravite, _ statut: Statut, _ categorie: Categorie, _ titre: String, _ explication: String, _ fichier: String, _ extrait: String) {
            examen.constats.append(Constat(id: "", gravite: gravite, statut: statut, categorie: categorie, titre: titre, fichier: fichier, lignes: [],
                                           extrait: String(extrait.prefix(300)), explication: explication, origine: .regle, regle: regle))
        }
        var dossiersVus = Set<String>(), apps = 0
        for f in fichiers {
            let composants = f.chemin.split(separator: "/").map(String.init)
            // Noms trompeurs : sur le fichier, et sur chaque dossier qui le contient (une app est un dossier).
            for (i, nom) in composants.enumerated() {
                let chemin = composants[...i].joined(separator: "/")
                guard i == composants.count - 1 || dossiersVus.insert(chemin).inserted else { continue }
                if doubleSuffixe.firstMatch(in: nom, range: NSRange(location: 0, length: (nom as NSString).length)) != nil {
                    constat("fic.double-suffixe", .elevee, .suspect, .obfuscation, "Nom qui se fait passer pour un document",
                            "Le nom finit comme un document, mais le vrai type est un programme : l'extension finale est souvent masquée par le Finder.", chemin, nom)
                }
                if nom.unicodeScalars.contains(where: { (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }) || nom.contains("          ") {
                    constat("fic.nom-trompeur", .elevee, .suspect, .obfuscation, "Nom de fichier trompeur",
                            "Le nom contient des caractères qui inversent l'affichage, ou une longue série d'espaces qui pousse la vraie extension hors de vue.", chemin, nom)
                }
            }
            if f.suffixe == "mobileconfig" {
                constat("fic.profil", .elevee, .suspect, .persistance, "Profil de configuration",
                        "Une fois installé, un profil peut ajouter un certificat, un proxy ou un VPN, et donc lire le trafic du Mac.", f.chemin, f.nom)
            } else if let (gravite, sorte) = lanceAuClic[f.suffixe] {
                constat("fic.lance-au-clic", gravite, .suspect, .autre, "Fichier qui lance quelque chose au double-clic", "Type de fichier : \(sorte). L'ouvrir exécute ce qu'il contient ou ce qu'il désigne.", f.chemin, f.nom)
            }

            let estPlist = f.format == "plist binaire" || f.suffixe == "plist"
            guard estPlist, f.taille <= plistMax, let donnees = try? Data(contentsOf: URL(fileURLWithPath: base + "/" + f.chemin)), let objet = plist(donnees) else { continue }
            var lieu = f.chemin
            if f.format == "plist binaire", let lignes = enClair(objet) {
                lieu = "\(f.chemin) [contenu]"
                examen.fiches.append(.fiche(lieu, ["Réglages en format binaire, réécrits en texte par Cerbère (données de la cible auditée) :"] + lignes))
            }
            guard let reglages = objet as? [String: Any] else { continue }
            // Agent ou démon de lancement : par son emplacement, ou par ses clés.
            let dansLancement = composants.dropLast().contains { $0 == "LaunchAgents" || $0 == "LaunchDaemons" }
            if dansLancement || (reglages["Label"] != nil && (reglages["ProgramArguments"] != nil || reglages["Program"] != nil || reglages["BundleProgram"] != nil)) {
                let commande = texte(reglages["ProgramArguments"] ?? reglages["Program"] ?? reglages["BundleProgram"])
                let demon = composants.contains("LaunchDaemons")
                var details = ["Label : \(texte(reglages["Label"]))", "commande : \(commande)"]
                if reglages["RunAtLoad"] as? Bool == true { details.append("lancé au démarrage") }
                if reglages["KeepAlive"] != nil { details.append("relancé s'il s'arrête") }
                if let s = reglages["StartInterval"] { details.append("toutes les \(texte(s)) s") }
                constat("app.agent", demon ? .elevee : .moyenne, .suspect, .persistance, demon ? "Démon de lancement embarqué" : "Agent de lancement embarqué",
                        (demon ? "Programme relancé à chaque démarrage du Mac, avec les droits d'administrateur." : "Programme relancé à chaque ouverture de session, sans fenêtre.")
                            + " Légitime pour une mise à jour ou une synchronisation, à condition que ce soit annoncé.", lieu, details.joined(separator: " ; "))
            }
            // Fiche d'identité d'une app.
            guard f.nom == "Info.plist", composants.count >= 3, composants[composants.count - 2] == "Contents",
                  (composants[composants.count - 3] as NSString).pathExtension.lowercased() == "app", apps < 12 else { continue }
            apps += 1
            let app = composants.dropLast(2).joined(separator: "/")
            let imbriquee = composants.dropLast(3).contains { ($0 as NSString).pathExtension.lowercased() == "app" }
            let principal = reglages["CFBundleExecutable"] as? String ?? ""
            if !principal.isEmpty, !principal.contains("/"), let programme = parChemin["\(app)/Contents/MacOS/\(principal)"] {
                if programme.nature == .texte {
                    constat("app.lanceur-script", .moyenne, .suspect, .obfuscation, "Le programme principal de l'app est un script",
                            "L'app n'est qu'un emballage autour d'un script : sa signature ne protège pas ce que le script lance.", programme.chemin, programme.lignes.first ?? "")
                } else if !imbriquee, let d = try? Data(contentsOf: URL(fileURLWithPath: base + "/" + programme.chemin), options: .mappedIfSafe) {
                    empreintes.append(EmpreinteNommee(nom: programme.chemin, sha256: Plateforme.sha256(d)))
                }
            } else if !imbriquee {
                constat("app.sans-programme", .moyenne, .suspect, .autre, "Programme principal introuvable", "L'app annonce un programme principal qui n'est pas dans son dossier.", lieu, "CFBundleExecutable = \(principal)")
            }
            if reglages["LSUIElement"] as? Bool == true || texte(reglages["LSUIElement"]) == "1" || reglages["LSBackgroundOnly"] as? Bool == true || texte(reglages["LSBackgroundOnly"]) == "1" {
                constat("app.cachee", imbriquee ? .info : .moyenne, .suspect, .autre, "App sans icône dans le Dock",
                        "L'app tourne sans fenêtre ni icône dans le Dock. Normal pour un utilitaire de barre de menus ou un assistant, à savoir sinon.", lieu, "LSUIElement / LSBackgroundOnly = oui")
            }
            if (reglages["NSAppTransportSecurity"] as? [String: Any])?["NSAllowsArbitraryLoads"] as? Bool == true {
                constat("app.http", .faible, .confirme, .reseau, "Connexions non chiffrées autorisées", "L'app s'autorise à parler en clair (http) avec n'importe quel serveur.", lieu, "NSAllowsArbitraryLoads = oui")
            }
            if let assistants = reglages["SMPrivilegedExecutables"] as? [String: Any], !assistants.isEmpty {
                constat("app.assistant-admin", .moyenne, .confirme, .persistance, "Installe un assistant qui tourne en administrateur",
                        "L'app peut installer un programme permanent avec tous les droits (après ton mot de passe).", lieu, "SMPrivilegedExecutables : " + assistants.keys.sorted().joined(separator: ", "))
            }
            if !imbriquee {
                let demandes = usages.filter { reglages[$0.0] != nil }.map(\.1)
                let schemas = (reglages["CFBundleURLTypes"] as? [[String: Any]] ?? []).flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
                var resume = ["identifiant \(texte(reglages["CFBundleIdentifier"]))", "version \(texte(reglages["CFBundleShortVersionString"]))"]
                if !demandes.isEmpty { resume.append("autorisations demandées : " + demandes.joined(separator: ", ")) }
                if !schemas.isEmpty { resume.append("liens ouverts par l'app : " + schemas.prefix(8).joined(separator: ", ")) }
                constat("app.identite", .info, .confirme, .autre, "Ce que l'app annonce", "Tiré de sa fiche d'identité (Info.plist), écrite par son auteur.", lieu, resume.joined(separator: " ; "))
            }
        }
        return (examen, empreintes)
    }
}

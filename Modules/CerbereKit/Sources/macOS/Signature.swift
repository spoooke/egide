import Foundation

/// Signature d'une app, d'un binaire ou d'une image disque, lue avec `codesign` (outil du système, en lecture) :
/// qui a signé, si le contenu a changé depuis, quels droits sont demandés (entitlements). Tout est local.
/// Le verdict de Gatekeeper (`spctl`) n'est demandé qu'avec l'accord de l'utilisateur : pour le rendre,
/// macOS peut interroger Apple.
enum Signature {
    enum Sorte: Sendable { case app, binaire, image }

    enum Signataire: Equatable, Sendable {
        case aucun, locale, apple, appStore, developpeur, developpement
        /// Certificat qui ne remonte pas à Apple (les noms affichés ne prouvent alors rien).
        case inconnu
    }

    struct Etat: Sendable {
        var signataire = Signataire.aucun
        var identifiant = ""
        var autorites: [String] = []
        var equipe = ""
        var options = ""
        var date = ""
        var ticket = false
        /// nil : pas de vérification (rien à vérifier, ou outil arrêté).
        var valide: Bool?
        var alteree = false
        var erreur = ""
        var droits: [(cle: String, valeur: String)] = []
        var gatekeeper: (accepte: Bool, detail: String)?
    }

    private static let codesign = "/usr/bin/codesign"

    static func lire(_ chemin: URL, sorte: Sorte, gatekeeper: Bool, annulation: Annulation? = nil) -> Etat {
        var e = Etat()
        let affichage = Outil.lancer(codesign, ["-d", "--verbose=4", chemin.path], annulation: annulation, delai: 60).tout
        func champ(_ nom: String) -> String {
            affichage.split(whereSeparator: \.isNewline).first { $0.hasPrefix(nom + "=") }.map { String($0.dropFirst(nom.count + 1)) } ?? ""
        }
        let signe = !affichage.contains("not signed at all") && affichage.contains("CodeDirectory")
        if signe {
            e.identifiant = champ("Identifier")
            e.autorites = affichage.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("Authority=") }.map { String($0.dropFirst(10)) }
            e.equipe = champ("TeamIdentifier") == "not set" ? "" : champ("TeamIdentifier")
            e.date = champ("Timestamp").isEmpty ? champ("Signed Time") : champ("Timestamp")
            e.ticket = champ("Notarization Ticket") == "stapled"
            if let debut = affichage.range(of: "flags=")?.upperBound {
                let options = affichage[debut...].prefix { !$0.isWhitespace }
                e.options = options.firstIndex(of: "(").map { String(options[options.index(after: $0)...].dropLast()) } ?? ""
            }
            let locale = champ("Signature") == "adhoc" || e.options.contains("adhoc")
            // Vérification complète : chaque fichier scellé est comparé à son empreinte, code imbriqué compris.
            let verification = Outil.lancer(codesign, ["--verify", "--deep", "--strict", "--verbose=2", chemin.path], annulation: annulation, delai: 600)
            if !verification.horsDelai {
                e.valide = verification.code == 0
                if verification.code != 0 {
                    e.erreur = String(verification.erreur.split(whereSeparator: \.isNewline).first { !$0.hasPrefix("--") } ?? "").replacingOccurrences(of: chemin.path, with: chemin.lastPathComponent)
                    e.alteree = ["modified", "invalid signature", "sealed resource is missing", "invalid Info.plist", "invalid resource"].contains { verification.erreur.contains($0) }
                }
            }
            if locale { e.signataire = .locale }
            // Les noms des certificats sont écrits par le signataire : seule la remontée jusqu'à la racine d'Apple les rend fiables.
            else if Outil.lancer(codesign, ["--verify", "-R=anchor apple generic", chemin.path], annulation: annulation, delai: 600).code != 0,
                    e.valide == true || e.autorites.last != "Apple Root CA" { e.signataire = .inconnu }
            else {
                let premier = e.autorites.first ?? ""
                e.signataire = premier.hasPrefix("Developer ID ") ? .developpeur
                    : premier.contains("Application Signing") ? .appStore
                    : premier.hasSuffix("Software Signing") ? .apple
                    : premier.hasPrefix("Apple Development") || premier.hasPrefix("Mac Developer") || premier.hasPrefix("Apple Distribution") || premier.hasPrefix("iPhone") ? .developpement
                    : e.autorites.isEmpty ? .inconnu : .developpement
            }
            if sorte != .image, let droits = Outil.lancer(codesign, ["-d", "--entitlements", "-", "--xml", chemin.path], annulation: annulation, delai: 60).sortie.data(using: .utf8),
               let liste = (try? PropertyListSerialization.propertyList(from: droits, format: nil)) as? [String: Any] {
                e.droits = liste.sorted { $0.key < $1.key }.map { ($0.key, texte($0.value)) }
            }
        }
        if gatekeeper {
            let type = sorte == .image ? ["--type", "open", "--context", "context:primary-signature"] : ["--type", "execute"]
            let avis = Outil.lancer("/usr/sbin/spctl", ["--assess"] + type + ["-vv", chemin.path], annulation: annulation, delai: 300)
            if !avis.horsDelai {
                let lignes = avis.tout.split(whereSeparator: \.isNewline).map { $0.replacingOccurrences(of: chemin.path, with: chemin.lastPathComponent) }
                e.gatekeeper = (avis.code == 0, lignes.prefix(4).joined(separator: " ; "))
            }
        }
        return e
    }

    private static func texte(_ valeur: Any) -> String {
        switch valeur {
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): n.boolValue ? "oui" : "non"
        case let liste as [Any]: liste.map(texte).joined(separator: ", ")
        case let d as [String: Any]: d.sorted { $0.key < $1.key }.map { "\($0.key): \(texte($0.value))" }.joined(separator: ", ")
        default: "\(valeur)"
        }
    }

    // MARK: - Droits demandés

    private struct Droit {
        let prefixe: String
        let gravite: Gravite
        let titre: String
        let explication: String
    }

    private static let droitsSensibles: [Droit] = [
        Droit(prefixe: "com.apple.security.cs.disable-library-validation", gravite: .moyenne, titre: "Peut charger des bibliothèques d'autres éditeurs",
              explication: "L'app désactive le contrôle qui l'empêche de charger du code signé par quelqu'un d'autre : une bibliothèque déposée à côté serait chargée."),
        Droit(prefixe: "com.apple.security.cs.allow-dyld-environment-variables", gravite: .moyenne, titre: "Accepte du code injecté par variable d'environnement",
              explication: "Une variable d'environnement peut faire charger une autre bibliothèque au lancement."),
        Droit(prefixe: "com.apple.security.cs.disable-executable-page-protection", gravite: .moyenne, titre: "Protection de la mémoire exécutable désactivée",
              explication: "L'app peut modifier son propre code en mémoire : utile à de rares outils, pratique pour cacher du code."),
        Droit(prefixe: "com.apple.security.get-task-allow", gravite: .moyenne, titre: "Version de mise au point",
              explication: "Ce droit laisse un autre programme prendre la main sur l'app : il n'a rien à faire dans une version distribuée."),
        Droit(prefixe: "com.apple.security.cs.debugger", gravite: .moyenne, titre: "Peut prendre la main sur d'autres programmes",
              explication: "Droit des débogueurs : l'app peut lire et modifier la mémoire d'autres programmes."),
        Droit(prefixe: "com.apple.private.", gravite: .elevee, titre: "Droit réservé à Apple",
              explication: "Les droits « private » sont réservés aux logiciels d'Apple : macOS les refuse ailleurs, et les demander est anormal."),
        Droit(prefixe: "com.apple.security.cs.allow-unsigned-executable-memory", gravite: .faible, titre: "Mémoire exécutable non signée",
              explication: "L'app peut fabriquer du code en mémoire et le lancer. Courant pour les apps qui embarquent un moteur de script."),
        Droit(prefixe: "com.apple.security.automation.apple-events", gravite: .faible, titre: "Peut piloter d'autres apps",
              explication: "L'app peut envoyer des commandes à d'autres apps (macOS demandera ton accord pour chacune)."),
        Droit(prefixe: "com.apple.security.temporary-exception.", gravite: .faible, titre: "Exception au bac à sable",
              explication: "L'app sort de son bac à sable pour un usage précis."),
        Droit(prefixe: "com.apple.developer.endpoint-security.client", gravite: .faible, titre: "Surveillance du système",
              explication: "Droit des outils de sécurité : l'app voit ce que font les autres programmes."),
        Droit(prefixe: "com.apple.developer.system-extension.install", gravite: .faible, titre: "Installe une extension système",
              explication: "L'app installe un composant qui tourne en permanence avec des droits étendus (réseau, pilote, sécurité)."),
        Droit(prefixe: "com.apple.developer.networking.networkextension", gravite: .faible, titre: "Extension réseau",
              explication: "L'app peut filtrer ou détourner le trafic réseau du Mac (VPN, filtre, proxy)."),
    ]

    /// Accès annoncés, sans gravité : regroupés dans un seul constat.
    private static let acces: [(String, String)] = [
        ("com.apple.security.device.camera", "caméra"), ("com.apple.security.device.microphone", "micro"),
        ("com.apple.security.device.audio-input", "micro"), ("com.apple.security.personal-information.location", "position"),
        ("com.apple.security.personal-information.addressbook", "contacts"), ("com.apple.security.personal-information.calendars", "calendriers"),
        ("com.apple.security.personal-information.photos-library", "photos"), ("com.apple.security.files.all", "tous les fichiers"),
        ("com.apple.security.files.downloads.read-write", "Téléchargements"), ("com.apple.security.files.user-selected.read-write", "fichiers choisis"),
        ("com.apple.security.network.client", "réseau (sortant)"), ("com.apple.security.network.server", "réseau (entrant)"),
        ("com.apple.security.device.usb", "USB"), ("com.apple.security.device.bluetooth", "Bluetooth"),
        ("keychain-access-groups", "trousseau partagé"),
    ]

    // MARK: - Fiche et constats

    /// Examine un élément là où il se trouve (ses liens internes sont nécessaires à la vérification) et ajoute
    /// la fiche lisible et les constats. `fiable` : faux pour une copie sortie d'une archive, où une vérification
    /// ratée peut venir de l'extraction.
    static func examiner(_ chemin: URL, nom: String, sorte: Sorte, fiable: Bool = true, gatekeeper: Bool, annulation: Annulation? = nil,
                         dans examen: inout Examen) {
        let e = lire(chemin, sorte: sorte, gatekeeper: gatekeeper, annulation: annulation)
        guard annulation?.demandee != true else { return }
        let fiche = "\(nom) [signature]"
        let quoi = sorte == .app ? "l'app" : sorte == .image ? "l'image disque" : "le programme"
        var lignes = ["Fiche produite par Cerbère avec codesign, en lecture seule : \(quoi) n'a pas été lancé\(sorte == .binaire ? "" : "e"). Les noms ci-dessous sont écrits par le signataire."]
        var constats: [Constat] = []
        func constat(_ regle: String, _ gravite: Gravite, _ statut: Statut, _ titre: String, _ explication: String, ligne: String, categorie: Categorie = .autre) {
            lignes.append(ligne)
            constats.append(Constat(id: "", gravite: gravite, statut: statut, categorie: categorie, titre: titre, fichier: fiche, lignes: [lignes.count, lignes.count],
                                    extrait: String(ligne.prefix(300)), explication: explication, origine: .regle, regle: regle))
        }
        if !e.identifiant.isEmpty { lignes.append("Identifiant : \(e.identifiant)") }
        if !e.autorites.isEmpty { lignes.append("Chaîne de certificats : " + e.autorites.joined(separator: " > ")) }
        if !e.equipe.isEmpty { lignes.append("Équipe : \(e.equipe)") }
        if !e.date.isEmpty { lignes.append("Signé le : \(e.date)") }
        if !e.options.isEmpty { lignes.append("Options : \(e.options)") }
        let nomSignataire = e.autorites.first ?? ""
        switch e.signataire {
        case .aucun:
            if sorte == .image {
                constat("sig.image", .info, .confirme, "Image disque non signée", "Courant : c'est la signature de l'app à l'intérieur qui compte.", ligne: "Signature : aucune")
            } else {
                constat("sig.absente", sorte == .app ? .elevee : .moyenne, .confirme, "Aucune signature",
                        "Rien ne dit qui a produit ce programme ni s'il a été modifié. macOS refuse de l'ouvrir s'il vient d'Internet.", ligne: "Signature : aucune")
            }
        case .locale:
            constat("sig.locale", sorte == .app ? .elevee : .faible, .confirme, "Signature locale, sans identité",
                    sorte == .app ? "L'app porte une signature « ad hoc » : elle ne nomme aucun développeur et Apple ne l'a pas contrôlée. macOS refuse de l'ouvrir si elle vient d'Internet."
                        : "Signature « ad hoc » : elle ne nomme personne. Normal pour un programme compilé sur place, à savoir pour un programme téléchargé.",
                    ligne: "Signature : locale (ad hoc), sans identité")
        case .inconnu:
            constat("sig.inconnue", .elevee, .confirme, "Certificat non reconnu par Apple",
                    "La signature ne remonte pas à Apple : le nom affiché a pu être choisi librement par celui qui a signé.", ligne: "Signature : \(nomSignataire) (certificat non reconnu par Apple)")
        case .developpement:
            constat("sig.developpement", .moyenne, .confirme, "Signé avec un certificat de développement",
                    "Ce certificat sert à essayer une app sur ses propres machines, pas à la distribuer : Apple ne l'a pas contrôlée.", ligne: "Signature : \(nomSignataire)")
        case .apple:
            constat("sig.identite", .info, .confirme, "Signé par Apple", "Logiciel d'Apple.", ligne: "Signature : Apple (\(nomSignataire))")
        case .appStore:
            constat("sig.identite", .info, .confirme, "Vient du Mac App Store", "App distribuée par le Mac App Store : Apple l'a contrôlée avant de la publier.", ligne: "Signature : Mac App Store (\(nomSignataire))")
        case .developpeur:
            constat("sig.identite", .info, .confirme, "Signé par un développeur identifié", "Le certificat « Developer ID » remonte à Apple : il dit qui a signé, pas que le logiciel est sain.",
                    ligne: "Signature : \(nomSignataire)" + (e.ticket ? ", ticket de notarisation agrafé" : ""))
        }
        if let valide = e.valide {
            if valide { lignes.append("Vérification du contenu (codesign --verify --deep --strict) : conforme à la signature") }
            else if e.alteree {
                constat("sig.alteree", fiable ? .critique : .elevee, fiable ? .confirme : .suspect, "Contenu modifié après la signature",
                        "Un fichier ne correspond plus à ce que le développeur a signé : \(quoi) a été modifié\(sorte == .binaire ? "" : "e") depuis."
                            + (fiable ? "" : " Vérification faite sur une copie sortie d'une archive : à refaire sur l'app elle-même."),
                        ligne: "Vérification du contenu : échec — \(e.erreur)")
            } else {
                constat("sig.invalide", .moyenne, .suspect, "Signature refusée par la vérification",
                        "La vérification stricte échoue, sans qu'on puisse dire que le contenu a été modifié.", ligne: "Vérification du contenu : échec — \(e.erreur)")
            }
        }
        if e.signataire == .developpeur {
            if e.ticket { lignes.append("Ticket de notarisation agrafé : oui (Apple a contrôlé cette version ; la preuve complète est le verdict de Gatekeeper)") }
            else if e.gatekeeper == nil {
                constat("sig.ticket", .faible, .suspect, "Pas de ticket de notarisation agrafé",
                        "On ne peut pas dire sans interroger Apple si cette version a été notarisée. La vérification Gatekeeper le dira.", ligne: "Ticket de notarisation agrafé : non")
            }
            if sorte != .image, !e.options.contains("runtime") {
                constat("sig.runtime", .faible, .confirme, "Protections d'exécution non activées",
                        "L'app n'active pas le « hardened runtime », qui empêche l'injection de code. Apple l'exige pour notariser.", ligne: "Protections d'exécution (hardened runtime) : non")
            }
        }
        if let g = e.gatekeeper {
            if g.accepte { constat("sig.gatekeeper", .info, .confirme, "Accepté par Gatekeeper", "macOS accepte d'ouvrir cet élément (signature reconnue, notarisation vérifiée).", ligne: "Gatekeeper (spctl) : accepté — \(g.detail)") }
            else if sorte == .image && e.signataire == .aucun { lignes.append("Gatekeeper (spctl) : sans avis sur une image non signée — \(g.detail)") }
            else { constat("sig.gatekeeper-refus", .elevee, .confirme, "Refusé par Gatekeeper", "macOS refuserait d'ouvrir cet élément s'il venait d'Internet.", ligne: "Gatekeeper (spctl) : refusé — \(g.detail)") }
        } else if sorte != .binaire { lignes.append("Gatekeeper (spctl) : non demandé (macOS peut interroger Apple ; seulement avec ton accord)") }

        if sorte != .image, e.signataire != .aucun {
            lignes.append("Droits demandés (entitlements) : \(e.droits.isEmpty ? "aucun" : "\(e.droits.count)")")
            var annonces: [String] = []
            for (cle, valeur) in e.droits {
                let ligne = "  \(cle) = \(valeur.prefix(300))"
                if valeur == "non" { lignes.append(ligne); continue }
                if let d = droitsSensibles.first(where: { cle.hasPrefix($0.prefixe) }), !(d.prefixe == "com.apple.private." && e.signataire == .apple) {
                    constat("droit." + String(d.prefixe.split(separator: ".").last ?? "autre"), d.gravite, d.gravite == .elevee ? .suspect : .confirme, d.titre, d.explication, ligne: ligne)
                } else {
                    lignes.append(ligne)
                    if let a = acces.first(where: { $0.0 == cle }), !annonces.contains(a.1) { annonces.append(a.1) }
                }
            }
            if sorte == .app {
                let bacASable = e.droits.contains { $0.cle == "com.apple.security.app-sandbox" && $0.valeur == "oui" }
                constat("droit.acces", .info, .confirme, bacASable ? "App en bac à sable" : "App hors bac à sable",
                        (bacASable ? "L'app n'a accès qu'à ce qu'elle déclare" : "L'app n'est pas enfermée dans un bac à sable : elle peut lire les fichiers de ton compte, dans la limite des autorisations de macOS")
                            + (annonces.isEmpty ? "." : " ; accès déclarés : \(annonces.joined(separator: ", "))."),
                        ligne: "Bac à sable : \(bacASable ? "oui" : "non")" + (annonces.isEmpty ? "" : " ; accès déclarés : \(annonces.joined(separator: ", "))"))
            }
        }
        examen.fiches.append(.fiche(fiche, lignes))
        examen.constats += constats
    }

    /// Apps trouvées dans un dossier dont les liens sont intacts (volume monté, archive extraite, paquet ouvert) :
    /// chacune est examinée sur place. On ne descend pas dans une app (son code imbriqué est vérifié avec elle).
    static func examinerApps(dans base: URL, prefixe: String = "", fiable: Bool, gatekeeper: Bool, annulation: Annulation? = nil, dans examen: inout Examen) {
        let fm = FileManager.default
        guard let parcours = fm.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else { return }
        var vues = 0
        let racine = base.resolvingSymlinksInPath().path
        for case let url as URL in parcours {
            guard annulation?.demandee != true else { return }
            let valeurs = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard valeurs?.isDirectory == true, valeurs?.isSymbolicLink != true else { continue }
            if parcours.level > 6 { parcours.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "app" else { continue }
            parcours.skipDescendants()
            let relatif = String(url.resolvingSymlinksInPath().path.dropFirst(racine.count + 1))
            guard vues < appsMax else {
                examen.nonAnalyse.append(NonAnalyse(fichier: prefixe + relatif, raison: "signature non lue (plus de \(appsMax) apps)"))
                continue
            }
            vues += 1
            examiner(url, nom: prefixe + relatif, sorte: .app, fiable: fiable, gatekeeper: gatekeeper, annulation: annulation, dans: &examen)
        }
    }

    static let appsMax = 8
}

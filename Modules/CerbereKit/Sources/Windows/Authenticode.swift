import Foundation

/// Signature Authenticode d'un programme (.exe, .dll…) ou d'un paquet .msi, lue par PowerShell, en lecture seule.
/// - Toujours, sans rien envoyer : le certificat du signataire, lu dans le fichier (`CreateFromSignedFile`).
/// - Avec l'accord donné pour l'audit (`--authenticode`) : la vérification de Windows (`Get-AuthenticodeSignature`),
///   qui dit si le contenu a changé depuis la signature et si le certificat est reconnu ; pour le dire, Windows peut
///   interroger l'autorité de certification du signataire.
/// Le chemin du fichier est passé à PowerShell par une variable d'environnement, jamais dans le texte de la commande.
enum Authenticode {
    static var powershell: String { Plateforme.system32 + #"\WindowsPowerShell\v1.0\powershell.exe"# }

    /// Programmes examinés au plus dans un dossier (archive, conteneur), les moins profonds d'abord.
    static let programmesMax = 8
    static let suffixes: Set<String> = ["exe", "dll", "msi", "sys", "scr", "ocx", "cpl", "msix", "appx"]

    static func concerne(_ nom: String, format: String) -> Bool {
        let suffixe = (nom as NSString).pathExtension.lowercased()
        return format == "exécutable Windows" || (format == "document Office (OLE)" && suffixe == "msi")
    }

    struct Etat: Sendable {
        var signataire: String?
        var emetteur: String?
        var lisible = true
        /// Vérification de Windows (`Get-AuthenticodeSignature`), si elle a été demandée et a répondu.
        var statut: String?
        var message = ""
        var systeme = false
    }

    private static let lecture = #"""
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        $p = $env:CERBERE_CIBLE
        try {
            $c = [System.Security.Cryptography.X509Certificates.X509Certificate]::CreateFromSignedFile($p)
            "SUJET`t" + $c.Subject
            "EMETTEUR`t" + $c.Issuer
        } catch { "AUCUNE`t" + $_.Exception.GetType().Name }
        """#

    private static let verification = #"""
        $s = Get-AuthenticodeSignature -LiteralPath $env:CERBERE_CIBLE
        "STATUT`t" + $s.Status
        "MESSAGE`t" + ($s.StatusMessage -replace "`r|`n", " ")
        "SYSTEME`t" + $s.IsOSBinary
        """#

    static func lire(_ fichier: URL, verifier: Bool, annulation: Annulation?) -> Etat {
        var etat = Etat()
        let script = lecture + (verifier ? "\n" + verification : "")
        let r = Outil.lancer(powershell, ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script], annulation: annulation,
                             delai: verifier ? 120 : 60, ajouts: ["CERBERE_CIBLE": Plateforme.cheminOutil(fichier.path)])
        guard r.code == 0 else {
            etat.lisible = false
            return etat
        }
        for ligne in r.sortie.split(whereSeparator: \.isNewline) {
            let morceaux = ligne.split(separator: "\t", maxSplits: 1).map(String.init)
            guard morceaux.count == 2 else { continue }
            let valeur = morceaux[1].trimmingCharacters(in: .whitespaces)
            switch morceaux[0] {
            case "SUJET": etat.signataire = valeur
            case "EMETTEUR": etat.emetteur = valeur
            case "STATUT": etat.statut = valeur
            case "MESSAGE": etat.message = String(valeur.prefix(300))
            case "SYSTEME": etat.systeme = valeur == "True"
            default: break
            }
        }
        return etat
    }

    /// « CN=Éditeur, O=…, C=FR » → « Éditeur ».
    static func nomCourant(_ sujet: String) -> String {
        sujet.components(separatedBy: ", ").first { $0.hasPrefix("CN=") }.map { String($0.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) } ?? sujet
    }

    /// Fiche `[signature]` et constats d'un programme ou d'un paquet .msi.
    static func examiner(_ fichier: URL, nom: String, gatekeeper verifier: Bool, annulation: Annulation?, dans examen: inout Examen) {
        let fiche = "\(nom) [signature]"
        var lignes = ["Fiche produite par Cerbère avec PowerShell, en lecture seule : le fichier n'a pas été lancé. Les noms ci-dessous sont écrits par le signataire."]
        var constats: [Constat] = []
        func constat(_ regle: String, _ gravite: Gravite, _ statut: Statut, _ titre: String, _ explication: String, ligne: String) {
            lignes.append(ligne)
            constats.append(Constat(id: "", gravite: gravite, statut: statut, categorie: .installation, titre: titre, fichier: fiche, lignes: [lignes.count, lignes.count],
                                    extrait: String(ligne.prefix(300)), explication: explication, origine: .regle, regle: regle))
        }
        let msi = (nom as NSString).pathExtension.lowercased() == "msi"
        let etat = lire(fichier, verifier: verifier, annulation: annulation)
        guard etat.lisible else {
            lignes.append("Signature : non lue (PowerShell n'a pas répondu)")
            examen.fiches.append(.fiche(fiche, lignes))
            examen.nonAnalyse.append(NonAnalyse(fichier: nom, raison: "signature Authenticode non lue"))
            return
        }
        if let signataire = etat.signataire {
            constat("sig.identite", .info, .confirme, "Signé par « \(nomCourant(signataire)) »",
                    "Nom écrit dans le certificat du signataire. Sans la vérification de Windows (--authenticode), il ne prouve ni l'identité ni que le fichier est intact.",
                    ligne: "Signature Authenticode présente : \(nomCourant(signataire))")
            lignes.append("Certificat du signataire : \(signataire)")
            if let emetteur = etat.emetteur { lignes.append("Délivré par : \(emetteur)") }
        } else if msi {
            constat("msi.non-signe", .moyenne, .confirme, "Paquet d'installation Windows non signé",
                    "Rien ne dit qui a produit ce paquet, qui s'installe d'ordinaire avec les droits d'administrateur. Windows prévient avant de l'ouvrir.",
                    ligne: "Signature : aucune")
        } else {
            lignes.append("Signature : aucune")
        }
        if let statut = etat.statut {
            let detail = etat.message.isEmpty ? statut : "\(statut) — \(etat.message)"
            switch statut {
            case "Valid":
                constat("sig.authenticode", .info, .confirme, "Signature reconnue par Windows",
                        "Le contenu n'a pas changé depuis la signature et le certificat remonte à une autorité reconnue. Cela dit qui a signé, pas que le logiciel est sain.",
                        ligne: "Vérification de Windows : valide" + (etat.systeme ? " (fichier de Windows)" : "") + " — \(detail)")
            case "HashMismatch":
                constat("sig.alteree", .critique, .confirme, "Contenu modifié après la signature",
                        "Le fichier ne correspond plus à ce qui a été signé : il a été modifié depuis, par exemple pour y glisser du code.",
                        ligne: "Vérification de Windows : contenu modifié — \(detail)")
            case "NotSigned":
                lignes.append("Vérification de Windows : non signé")
            default:
                constat("sig.invalide", .moyenne, .suspect, "Signature refusée par Windows",
                        "Windows ne reconnaît pas cette signature (certificat inconnu, expiré ou révoqué) : le nom du signataire ne prouve rien.",
                        ligne: "Vérification de Windows : refusée — \(detail)")
            }
        } else if verifier {
            lignes.append("Vérification de Windows : pas de réponse")
        } else if etat.signataire != nil {
            lignes.append("Validité de la signature : non vérifiée (Windows peut interroger l'autorité de certification ; seulement avec ton accord : --authenticode)")
        }
        examen.fiches.append(.fiche(fiche, lignes))
        examen.constats += constats
    }

    /// Programmes rangés dans un dossier (archive ouverte) : les moins profonds d'abord, `programmesMax` au plus.
    static func examinerDossier(_ base: URL, prefixe: String, gatekeeper: Bool, annulation: Annulation?, dans examen: inout Examen) {
        let fm = FileManager.default
        var trouves: [String] = []
        if let parcours = fm.enumerator(atPath: base.path) {
            for case let court as String in parcours {
                let relatif = Plateforme.relatif(court)
                guard suffixes.contains((relatif as NSString).pathExtension.lowercased()) else { continue }
                var dossier: ObjCBool = false
                if fm.fileExists(atPath: base.path + "/" + relatif, isDirectory: &dossier), !dossier.boolValue { trouves.append(relatif) }
            }
        }
        trouves.sort { ($0.components(separatedBy: "/").count, $0) < ($1.components(separatedBy: "/").count, $1) }
        for relatif in trouves.prefix(programmesMax) {
            guard annulation?.demandee != true else { return }
            let url = URL(fileURLWithPath: base.path + "/" + relatif)
            guard let lecture = try? FileHandle(forReadingFrom: url), let debut = try? lecture.read(upToCount: 512) else { continue }
            try? lecture.close()
            guard let format = Inventaire.format(debut)?.1, concerne(relatif, format: format) else { continue }
            examiner(url, nom: prefixe + relatif, gatekeeper: gatekeeper, annulation: annulation, dans: &examen)
        }
        for relatif in trouves.dropFirst(programmesMax) {
            examen.nonAnalyse.append(NonAnalyse(fichier: prefixe + relatif, raison: "signature non lue (plus de \(programmesMax) programmes)"))
        }
    }
}

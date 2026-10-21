import Foundation

/// Images disque et paquets d'installation du Mac : une image est montée en lecture seule, cachée du Finder, sans
/// ouverture automatique ; un paquet est développé par `pkgutil` (ses scripts sont lus, pas exécutés).
extension Quarantaine {
    static func ouvrirConteneurMac(_ fichier: URL, nature: Nature, nom: String, provisoire: URL, contenu: URL, gatekeeper: Bool,
                                   annulation: Annulation?, examen: inout Examen, _ lire: (URL, String) throws -> Void) throws {
        switch nature {
        case .image:
            Signature.examiner(fichier, nom: nom, sorte: .image, gatekeeper: gatekeeper, annulation: annulation, dans: &examen)
            // Lecture seule, cachée du Finder, sans ouverture automatique ni réparation : rien ne s'exécute au montage.
            let montage = Outil.lancer("/usr/bin/hdiutil", ["attach", "-plist", "-nobrowse", "-readonly", "-noautoopen", "-noautofsck", "-owners", "off",
                                                             "-mountrandom", provisoire.path, fichier.path], annulation: annulation, delai: 300)
            let entites = ((try? PropertyListSerialization.propertyList(from: Data(montage.sortie.utf8), format: nil)) as? [String: Any])?["system-entities"] as? [[String: Any]] ?? []
            let disques = entites.compactMap { $0["dev-entry"] as? String }.filter { $0.range(of: #"^/dev/disk\d+$"#, options: .regularExpression) != nil }
            defer { for disque in disques { _ = Outil.lancer("/usr/bin/hdiutil", ["detach", disque, "-force"], delai: 60) } }
            try annulation?.verifier()
            let volumes = entites.compactMap { $0["mount-point"] as? String }
            guard montage.code == 0, !volumes.isEmpty else {
                throw ErreurCerbere.archiveRefusee("image disque non montée (chiffrée, abîmée ou avec licence à accepter)")
            }
            for volume in volumes {
                let url = URL(fileURLWithPath: volume)
                let prefixe = volumes.count > 1 ? url.lastPathComponent + "/" : ""
                Signature.examinerApps(dans: url, prefixe: nom + "!/" + prefixe, fiable: true, gatekeeper: gatekeeper, annulation: annulation, dans: &examen)
                try lire(url, prefixe)
            }
        default:
            Paquet.examiner(fichier, nom: nom, gatekeeper: gatekeeper, annulation: annulation, dans: &examen)
            // pkgutil développe le paquet et sa charge sans rien installer ni lancer ; bsdtar en secours (charge non développée).
            let r = Outil.lancer("/usr/sbin/pkgutil", ["--expand-full", fichier.path, contenu.path], annulation: annulation, delai: 600)
            try annulation?.verifier()
            if r.code != 0 {
                Plateforme.supprimer(contenu)
                try extraire(fichier, vers: contenu, annulation: annulation)
            }
            rendreTraversable(contenu)
            Signature.examinerApps(dans: contenu, prefixe: nom + "!/", fiable: false, gatekeeper: gatekeeper, annulation: annulation, dans: &examen)
            try lire(contenu, "")
        }
    }
}

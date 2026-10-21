import Foundation
import Security

/// Paquet d'installation (.pkg) : qui l'a signé, et ce qu'il annonce. Lu sans l'installer.
enum Paquet {
    /// Noms des certificats rangés dans le paquet (le premier est celui du signataire). Lus sur place : cela dit
    /// qu'une signature est présente, pas qu'elle est valide.
    static func certificats(_ paquet: URL, annulation: Annulation? = nil) -> [String]? {
        let table = Outil.lancer("/usr/bin/xar", ["--dump-toc=-", "-f", paquet.path], annulation: annulation, delai: 60, max: 64_000_000)
        guard table.code == 0 else { return nil }
        guard table.sortie.contains("<signature ") else { return [] }
        var noms: [String] = []
        var reste = table.sortie[...]
        while let debut = reste.range(of: "<X509Certificate>"), let fin = reste.range(of: "</X509Certificate>", range: debut.upperBound..<reste.endIndex) {
            let texte = reste[debut.upperBound..<fin.lowerBound].filter { !$0.isWhitespace }
            if let der = Data(base64Encoded: String(texte)), let certificat = SecCertificateCreateWithData(nil, der as CFData),
               let nom = SecCertificateCopySubjectSummary(certificat) as String? { noms.append(nom) }
            reste = reste[fin.upperBound...]
            if noms.count >= 6 { break }
        }
        return noms
    }

    static func examiner(_ paquet: URL, nom: String, gatekeeper: Bool, annulation: Annulation? = nil, dans examen: inout Examen) {
        let fiche = "\(nom) [signature]"
        var lignes = ["Fiche produite par Cerbère avec xar\(gatekeeper ? ", pkgutil et spctl" : "") : le paquet a été lu sans être installé, aucun de ses scripts n'a été lancé. Les noms ci-dessous sont écrits par le signataire."]
        var constats: [Constat] = []
        func constat(_ regle: String, _ gravite: Gravite, _ statut: Statut, _ titre: String, _ explication: String, ligne: String) {
            lignes.append(ligne)
            constats.append(Constat(id: "", gravite: gravite, statut: statut, categorie: .installation, titre: titre, fichier: fiche, lignes: [lignes.count, lignes.count],
                                    extrait: String(ligne.prefix(300)), explication: explication, origine: .regle, regle: regle))
        }
        switch certificats(paquet, annulation: annulation) {
        case nil: lignes.append("Signature : illisible (table du paquet non lue)")
        case let noms? where noms.isEmpty:
            constat("pkg.non-signe", .elevee, .confirme, "Paquet d'installation non signé",
                    "Rien ne dit qui a produit ce paquet. Un paquet s'installe avec les droits d'administrateur : macOS refuse d'ouvrir celui-ci s'il vient d'Internet.",
                    ligne: "Signature : aucune")
        case let noms?:
            lignes.append("Signature présente : \(noms[0])")
            lignes.append("Chaîne de certificats : " + noms.joined(separator: " > "))
            if !noms[0].hasPrefix("Developer ID Installer") && !noms[0].contains("Apple") && !noms[0].contains("Software Update") {
                constat("pkg.signataire", .moyenne, .suspect, "Paquet signé sans certificat de distribution",
                        "Le certificat n'est pas un « Developer ID Installer » : Apple n'a pas contrôlé ce paquet.", ligne: "Type de certificat : autre que Developer ID Installer")
            }
        }
        if gatekeeper {
            let verification = Outil.lancer("/usr/sbin/pkgutil", ["--check-signature", paquet.path], annulation: annulation, delai: 120)
            let etat = verification.sortie.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("Status:") || $0.hasPrefix("Notarization:") }.joined(separator: " ; ")
            if !etat.isEmpty { lignes.append("Vérification (pkgutil --check-signature) : \(etat)") }
            let avis = Outil.lancer("/usr/sbin/spctl", ["--assess", "--type", "install", "-vv", paquet.path], annulation: annulation, delai: 300)
            let detail = avis.tout.split(whereSeparator: \.isNewline).map { $0.replacingOccurrences(of: paquet.path, with: paquet.lastPathComponent) }.prefix(4).joined(separator: " ; ")
            if avis.horsDelai { lignes.append("Gatekeeper (spctl) : pas de réponse") }
            else if avis.code == 0 { constat("sig.gatekeeper", .info, .confirme, "Accepté par Gatekeeper", "macOS accepte d'installer ce paquet (signature reconnue, notarisation vérifiée).", ligne: "Gatekeeper (spctl) : accepté — \(detail)") }
            else { constat("sig.gatekeeper-refus", .elevee, .confirme, "Refusé par Gatekeeper", "macOS refuserait d'ouvrir ce paquet s'il venait d'Internet.", ligne: "Gatekeeper (spctl) : refusé — \(detail)") }
        } else {
            lignes.append("Validité de la signature et notarisation : non vérifiées (macOS peut interroger Apple ; seulement avec ton accord)")
        }
        examen.fiches.append(.fiche(fiche, lignes))
        examen.constats += constats
    }
}

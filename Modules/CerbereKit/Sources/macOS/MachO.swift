import Foundation

/// Programmes du Mac (Mach-O) : bibliothèques liées et fonctions importées, lues par `otool` et `nm` ; textes par `strings`.
extension Binaires {
    static let outilChaines = "strings"

    static func importsMachO(_ f: Fichier, chemin: String, resume: Bool, annulation: Annulation?) -> Examen {
        var examen = Examen()
        var constats: [Constat] = []
        let fiche = "\(f.chemin) [imports]"
        var lignes = ["Fiche produite par Cerbère avec otool et nm, en lecture seule : le programme n'a pas été lancé. Elle dit ce qu'il peut appeler, pas ce qu'il fait."]
        func constat(_ regle: String, _ gravite: Gravite, _ statut: Statut, _ categorie: Categorie, _ titre: String, _ explication: String, ligne: Int) {
            constats.append(Constat(id: "", gravite: gravite, statut: statut, categorie: categorie, titre: titre, fichier: fiche, lignes: [ligne, ligne],
                                    extrait: String(lignes[ligne - 1].trimmingCharacters(in: .whitespaces).prefix(300)), explication: explication, origine: .regle, regle: regle))
        }
        let liees = Outil.lancer("/usr/bin/otool", ["-L", chemin], annulation: annulation, delai: 60).sortie.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("\t") }.map { String($0.dropFirst().prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces) }
        var bibliotheques: [String] = []
        for b in liees where !bibliotheques.contains(b) { bibliotheques.append(b) }
        lignes.append("Bibliothèques liées (\(bibliotheques.count)) :")
        for b in bibliotheques.prefix(400) {
            lignes.append("  " + b)
            // Hors du système et hors de l'app : la bibliothèque sera cherchée à un endroit que d'autres peuvent écrire.
            if b.hasPrefix("/"), !["/usr/lib/", "/System/", "/Library/Apple/"].contains(where: b.hasPrefix), (b as NSString).lastPathComponent != f.nom {
                constat("bin.bibliotheque", .moyenne, .suspect, .autre, "Bibliothèque chargée hors de l'app et du système",
                        "Le programme charge une bibliothèque à un chemin fixe du disque : celui qui écrit à cet endroit fait exécuter son code.", ligne: lignes.count)
            }
        }
        let nm = Outil.lancer("/usr/bin/nm", ["-u", chemin], annulation: annulation, delai: 120, max: 64_000_000)
        var vus = Set<String>(), symboles: [String] = []
        for ligne in nm.sortie.split(whereSeparator: \.isNewline) {
            let s = ligne.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("_"), !s.contains(" "), vus.insert(s).inserted { symboles.append(s) }
        }
        lignes.append("Fonctions importées : \(symboles.count)\(nm.code != 0 ? " (table illisible)" : "")")
        var presentes: [String] = []
        for (nom, motifs) in familles {
            let trouves = symboles.filter { s in motifs.contains { correspond(s, $0) } }
            guard !trouves.isEmpty else { continue }
            presentes.append(nom)
            // Un nom Swift est long et codé : une seule mention suffit à dire que la classe est utilisée.
            var cites: [String] = []
            for s in trouves {
                let court = s.hasPrefix("_$s") ? (s.contains("URLSession") ? "URLSession (Swift)" : s.contains("NWConnection") ? "NWConnection (Swift)" : "Process (Swift)")
                    : s.replacingOccurrences(of: "_OBJC_CLASS_$_", with: "")
                if !cites.contains(court) { cites.append(court) }
            }
            lignes.append("  \(nom) : " + cites.prefix(40).joined(separator: ", "))
            for a in alertes where !a.symboles.isDisjoint(with: trouves) {
                constat(a.regle, a.gravite, .suspect, a.categorie, a.titre, a.explication, ligne: lignes.count)
            }
        }
        if resume {
            lignes.append("Ce que le programme peut faire, d'après ses fonctions importées : " + (presentes.isEmpty ? "rien de notable" : presentes.joined(separator: ", ")))
            constat("bin.capacites", .info, .confirme, .autre, "Ce que le programme peut appeler",
                    "Liste tirée des fonctions importées. C'est une capacité, pas une preuve d'usage ; un programme peut aussi cacher ses appels.", ligne: lignes.count)
        }
        // Les symboles Swift et C++ (noms codés) n'apprennent rien ici : seuls les noms C et Objective-C sont listés.
        let lisibles = symboles.filter { !$0.hasPrefix("_$s") && !$0.hasPrefix("__Z") && !$0.hasPrefix("_swift_") && !$0.hasPrefix("_objc_") }
        lignes.append("Autres fonctions importées (\(lisibles.count), au plus 1500 listées) :")
        for paquet in stride(from: 0, to: min(lisibles.count, 1500), by: 12) {
            lignes.append("  " + lisibles[paquet..<min(paquet + 12, min(lisibles.count, 1500))].map { $0.replacingOccurrences(of: "_OBJC_CLASS_$_", with: "") }.joined(separator: " "))
        }
        examen.fiches.append(.fiche(fiche, lignes))
        examen.constats = constats
        return examen
    }

    static func chaines(_ chemin: String, annulation: Annulation?) -> Outil.Resultat {
        Outil.lancer("/usr/bin/strings", ["-a", "-n", "6", chemin], annulation: annulation, delai: 180, max: 96_000_000)
    }
}

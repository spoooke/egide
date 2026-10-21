import Foundation

/// Programmes compilés sur Windows : les textes sont lus ici même ; un programme du Mac (Mach-O) n'a pas ses
/// fonctions importées lues (otool et nm n'existent que sur le Mac), seulement ses textes et son code machine.
extension Binaires {
    static let outilChaines = "une lecture de ses octets"

    static func importsMachO(_ f: Fichier, chemin: String, resume: Bool, annulation: Annulation?) -> Examen {
        var examen = Examen()
        examen.nonAnalyse.append(NonAnalyse(fichier: f.chemin, raison: "programme du Mac : fonctions importées non lues sur Windows"))
        return examen
    }

    /// Comme `strings -a -n 6` : suites d'au moins six caractères imprimables (ASCII), une par ligne.
    static func chaines(_ chemin: String, annulation: Annulation?, max: Int = 96_000_000) -> Outil.Resultat {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: chemin), options: .mappedIfSafe) else {
            return Outil.Resultat(code: 1, sortie: "", erreur: "illisible")
        }
        var sortie = [UInt8](), courant = [UInt8]()
        sortie.reserveCapacity(min(d.count, max))
        func fermer() {
            if courant.count >= 6, sortie.count < max {
                sortie += courant.prefix(max - sortie.count)
                sortie.append(0x0A)
            }
            courant.removeAll(keepingCapacity: true)
        }
        for (i, octet) in d.enumerated() {
            if i & 0xFFFFF == 0, annulation?.demandee == true { break }
            if (0x20...0x7E).contains(octet) || octet == 0x09 { courant.append(octet) } else { fermer() }
        }
        fermer()
        return Outil.Resultat(code: 0, sortie: String(decoding: sortie, as: UTF8.self), erreur: "")
    }
}

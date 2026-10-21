import Foundation

/// Analyses qui ne tiennent pas dans un simple motif : blocs encodés, lignes géantes, relevé des hôtes.
enum Analyses {
    private static let base64 = try! NSRegularExpression(pattern: "[A-Za-z0-9+/]{40,}={0,2}")
    private static let codeCache = try! NSRegularExpression(
        pattern: #"https?://|\b(curl|wget|eval|exec|powershell|osascript|subprocess|child_process|require\(|import\s+\w+|/bin/(ba|z)?sh|chmod|base64)\b|<script"#,
        options: [.caseInsensitive])
    private static let sourcesLisibles: Set<String> = ["js", "mjs", "cjs", "ts", "jsx", "tsx", "py", "sh", "bash", "zsh", "rb", "php", "pl", "ps1", "lua", "swift", "go", "rs", "java", "kt", "c", "cpp", "m"]

    /// Blocs base64 : décodés sur place (jamais exécutés) pour voir s'ils cachent du code, une adresse ou un programme.
    static func blocsEncodes(_ texte: Texte) -> [Constat] {
        let f = texte.fichier
        guard !f.estGenere else { return [] }
        var constats: [Constat] = [], longs = 0
        base64.enumerateMatches(in: texte.contenu as String, range: NSRange(location: 0, length: texte.contenu.length)) { resultat, _, arret in
            guard let plage = resultat?.range else { return }
            let numero = texte.ligne(plage.location)
            let ligne = f.lignes[numero - 1]
            // Images et polices intégrées, sommes de contrôle : usages ordinaires.
            if ligne.contains("data:image") || ligne.contains("data:font") || ligne.contains("data:application/font")
                || ligne.contains("sha512-") || ligne.contains("sha256-") || ligne.contains("sha1-") { return }
            var bloc = texte.contenu.substring(with: plage)
            // Un chemin ou un identifiant long n'est pas du base64 : il faut des majuscules, des minuscules et des chiffres.
            guard bloc.contains(where: \.isNumber), bloc.contains(where: \.isUppercase), bloc.contains(where: \.isLowercase) else { return }
            bloc = String(bloc.prefix(bloc.count - bloc.count % 4))
            guard let donnees = Data(base64Encoded: bloc) else { return }
            func constat(_ gravite: Gravite, _ titre: String, _ explication: String, _ extrait: String) {
                constats.append(Constat(id: "", gravite: f.estDocumentation ? gravite.attenuee : gravite, statut: .suspect,
                                        categorie: .obfuscation, titre: titre, fichier: f.chemin, lignes: [numero, numero],
                                        extrait: extrait, explication: explication, origine: .regle, regle: "obf.base64"))
            }
            if let (nature, format) = Inventaire.format(donnees), nature == .executable || donnees.count > 2000 {
                constat(.elevee, "Fichier caché dans un bloc encodé",
                        "Une fois décodé, ce bloc est un fichier \(format) de \(donnees.count) octets rangé dans du texte.",
                        texte.extrait(plage, largeur: 120))
            } else if donnees.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }) {
                let decode = String(decoding: donnees, as: UTF8.self)
                if codeCache.firstMatch(in: decode, range: NSRange(location: 0, length: (decode as NSString).length)) != nil {
                    constat(.elevee, "Code ou adresse caché dans un bloc encodé",
                            "Une fois décodé, ce bloc contient du code ou une adresse : il a été encodé pour ne pas être lu.",
                            "décodé : " + String(decode.prefix(200)))
                }
            } else if bloc.count >= 400, longs < 2 {
                longs += 1
                constat(.faible, "Long bloc encodé", "Bloc de \(bloc.count) caractères au contenu illisible (données, clé, image ou charge cachée).",
                        texte.extrait(plage, largeur: 120))
            }
            if constats.count >= 6 { arret.pointee = true }
        }
        return constats
    }

    /// Une ligne géante dans un fichier source : code compacté ou charge collée en fin de ligne.
    static func lignesGeantes(_ texte: Texte) -> [Constat] {
        let f = texte.fichier
        guard !f.estGenere, sourcesLisibles.contains(f.suffixe),
              let i = f.lignes.firstIndex(where: { $0.utf8.count > 5000 }) else { return [] }
        let ligne = f.lignes[i]
        // Du code repoussé très loin à droite pour sortir de l'écran.
        let pousse = ligne.range(of: #"\S[ \t]{200,}\S"#, options: .regularExpression) != nil
        return [Constat(id: "", gravite: pousse ? .elevee : .faible, statut: .suspect, categorie: .obfuscation,
                        titre: pousse ? "Code repoussé hors de l'écran" : "Ligne très longue dans un fichier source",
                        fichier: f.chemin, lignes: [i + 1, i + 1], extrait: String(ligne.prefix(160)) + "…",
                        explication: pousse ? "La ligne contient du code après un très long vide : il n'apparaît pas à l'écran sans défiler."
                            : "Ligne de \(ligne.utf8.count) caractères : code compacté ou généré, difficile à relire.",
                        origine: .regle, regle: "obf.ligne")]
    }

    private static let hote = try! NSRegularExpression(
        pattern: #"\b(?:https?|wss?|ftp|ssh|git|tcp)://(?:[^\s/@'"`<>]*@)?((?:[a-z0-9-]+\.)+[a-z]{2,24}|\d{1,3}(?:\.\d{1,3}){3})(?![a-z0-9.-])"#,
        options: [.caseInsensitive])

    /// Relevé de tous les domaines et adresses IP cités dans des URL.
    static func hotes(_ textes: [Texte]) -> Reseau {
        var releve: [String: (fichiers: [String], occurrences: Int)] = [:]
        for texte in textes {
            hote.enumerateMatches(in: texte.contenu as String, range: NSRange(location: 0, length: texte.contenu.length)) { resultat, _, _ in
                guard let plage = resultat?.range(at: 1) else { return }
                let nom = texte.contenu.substring(with: plage).lowercased()
                var entree = releve[nom] ?? ([], 0)
                entree.occurrences += 1
                if entree.fichiers.count < 5, !entree.fichiers.contains(texte.fichier.chemin) { entree.fichiers.append(texte.fichier.chemin) }
                releve[nom] = entree
            }
        }
        var reseau = Reseau()
        for (nom, entree) in releve.sorted(by: { ($0.value.occurrences, $1.key) > ($1.value.occurrences, $0.key) }) {
            let h = Reseau.Hote(nom: nom, fichiers: entree.fichiers, occurrences: entree.occurrences)
            if nom.last!.isNumber { reseau.adresses.append(h) } else { reseau.domaines.append(h) }
        }
        return reseau
    }
}

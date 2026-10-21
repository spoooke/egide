import Foundation

/// Documents qui peuvent porter du code : PDF (JavaScript, lancement de programme, pièces jointes) et documents
/// Office (macros VBA, objets embarqués). Le fichier est lu octet par octet ici même : il n'est ouvert par aucune
/// app, et rien de ce qu'il contient n'est lancé.
enum Documents {
    static let tailleMax = 150_000_000

    // MARK: - PDF

    private static let cles: [(nom: String, motif: String)] = [
        ("JavaScript", #"/(JavaScript|JS)(?![A-Za-z0-9])"#), ("ouverture", #"/(OpenAction|AA)(?![A-Za-z0-9])"#), ("lancement", #"/Launch(?![A-Za-z0-9])"#),
        ("pièce jointe", #"/EmbeddedFiles?(?![A-Za-z0-9])"#), ("envoi de formulaire", #"/SubmitForm(?![A-Za-z0-9])"#),
        ("autre document", #"/(GoToR|GoToE)(?![A-Za-z0-9])"#), ("contenu riche", #"/(RichMedia|XFA)(?![A-Za-z0-9])"#), ("chiffrement", #"/Encrypt(?![A-Za-z0-9])"#),
    ]

    /// Décompresse un flux « Flate » du PDF, en mémoire, dans la limite donnée.
    static func degonfler(_ flux: Data, max: Int = 4_000_000) -> Data? {
        guard flux.count > 2, flux.count <= max else { return nil }
        // En-tête zlib de deux octets, puis du « deflate » brut.
        guard let d = Plateforme.degonfler(Data(flux.dropFirst(2)), max: max * 8), d.count <= max * 8 else { return nil }
        return d
    }

    /// Un nom PDF peut être écrit avec des codes (`/J#61vaScript`) pour échapper aux recherches : on les remet en clair.
    static func nomsEnClair(_ texte: String) -> String {
        guard texte.contains("#") else { return texte }
        let code = try! NSRegularExpression(pattern: "#([0-9A-Fa-f]{2})")
        var resultat = texte
        for m in code.matches(in: texte, range: NSRange(location: 0, length: (texte as NSString).length)).reversed() {
            let hexa = (texte as NSString).substring(with: m.range(at: 1))
            if let v = UInt8(hexa, radix: 16), v >= 0x21, v < 0x7F, let plage = Range(m.range, in: resultat) { resultat.replaceSubrange(plage, with: String(UnicodeScalar(v))) }
        }
        return resultat
    }

    private static func texte(_ d: Data) -> String {
        // UTF-16 avec marque d'ordre (chaînes PDF), sinon un octet par caractère : aucun octet n'est perdu.
        if d.starts(with: [0xFE, 0xFF]), let s = String(data: d, encoding: .utf16) { return s }
        return String(data: d, encoding: .isoLatin1) ?? ""
    }

    static func pdf(_ donnees: Data, chemin: String) -> Examen {
        var examen = Examen()
        guard donnees.count <= 60_000_000 else {
            examen.nonAnalyse.append(NonAnalyse(fichier: chemin, raison: "PDF de plus de 60 Mo"))
            return examen
        }
        // Le texte du fichier (un caractère par octet), puis celui des flux compressés (où un PDF peut ranger ses objets).
        let lu = String(data: donnees, encoding: .isoLatin1) ?? ""
        var parties = [nomsEnClair(lu)]
        var flux: [Int: Data] = [:]
        let brut = lu as NSString
        let debutFlux = try! NSRegularExpression(pattern: #"(\d+)\s+\d+\s+obj\b(?:(?!endobj)[\s\S]){0,4000}?stream\r?\n"#)
        var total = 0
        for m in debutFlux.matches(in: lu, range: NSRange(location: 0, length: brut.length)).prefix(3000) {
            let debut = m.range.upperBound
            let fin = brut.range(of: "endstream", range: NSRange(location: debut, length: brut.length - debut))
            guard fin.location != NSNotFound, fin.location - debut <= 4_000_000, total < 60_000_000 else { continue }
            // Un caractère par octet : les positions dans le texte sont celles du fichier.
            guard let degonfle = degonfler(donnees.subdata(in: donnees.startIndex + debut ..< donnees.startIndex + fin.location)) else { continue }
            total += degonfle.count
            flux[Int(brut.substring(with: m.range(at: 1))) ?? -1] = degonfle
            if !degonfle.prefix(4096).contains(0) || degonfle.starts(with: [0xFE, 0xFF]) { parties.append(nomsEnClair(texte(degonfle))) }
        }
        let corpus = parties.joined(separator: "\n")
        let etendue = NSRange(location: 0, length: (corpus as NSString).length)
        var presents: [String: Int] = [:]
        for (nom, motif) in cles {
            let n = try! NSRegularExpression(pattern: motif).numberOfMatches(in: corpus, range: etendue)
            if n > 0 { presents[nom] = n }
        }
        guard !presents.isEmpty else { return examen }

        // Code JavaScript : chaîne entre parenthèses, chaîne en hexadécimal, ou renvoi vers un flux.
        var scripts: [String] = []
        let js = try! NSRegularExpression(pattern: #"/JS\s*(?:\(((?:\\.|[^\\()]|\((?:\\.|[^\\()])*\))*)\)|<([0-9A-Fa-f\s]+)>|(\d+)\s+\d+\s+R)"#)
        for m in js.matches(in: corpus, range: etendue).prefix(40) {
            let c = corpus as NSString
            if m.range(at: 1).location != NSNotFound {
                scripts.append(c.substring(with: m.range(at: 1)).replacingOccurrences(of: #"\\([nrt])"#, with: "\n", options: .regularExpression)
                    .replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression))
            } else if m.range(at: 2).location != NSNotFound {
                let hexa = c.substring(with: m.range(at: 2)).filter { !$0.isWhitespace }
                var octets = Data()
                var i = hexa.startIndex
                while let j = hexa.index(i, offsetBy: 2, limitedBy: hexa.endIndex), let o = UInt8(hexa[i..<j], radix: 16) { octets.append(o); i = j }
                scripts.append(texte(octets))
            } else if let numero = Int(c.substring(with: m.range(at: 3))) {
                if let d = flux[numero] { scripts.append(texte(d)) }
                else if case let objet = brut.range(of: "\n\(numero) 0 obj").location, objet != NSNotFound {
                    // Flux non compressé : le texte suit tel quel.
                    let suite = brut.substring(with: NSRange(location: objet, length: min(200_000, brut.length - objet)))
                    if let debut = suite.range(of: "stream"), let fin = suite.range(of: "endstream"), debut.upperBound < fin.lowerBound {
                        scripts.append(String(suite[debut.upperBound..<fin.lowerBound]))
                    }
                }
            }
        }
        let fiche = "\(chemin) [contenu]"
        var lignes = ["Fiche produite par Cerbère en lisant le PDF comme un fichier, sans l'ouvrir dans une app : ce qu'il contient d'actif. Le code ci-dessous est une donnée du document audité."]
        var constats: [Constat] = []
        func constat(_ regle: String, _ gravite: Gravite, _ titre: String, _ explication: String, ligne: String, categorie: Categorie = .autre) {
            lignes.append(ligne)
            constats.append(Constat(id: "", gravite: gravite, statut: .suspect, categorie: categorie, titre: titre, fichier: fiche, lignes: [lignes.count, lignes.count],
                                    extrait: ligne, explication: explication, origine: .regle, regle: regle))
        }
        let auto = presents["ouverture"] != nil
        if let n = presents["JavaScript"] {
            constat("pdf.javascript", auto ? .elevee : .moyenne, auto ? "PDF avec JavaScript lancé à l'ouverture" : "PDF avec JavaScript",
                    "Un PDF n'a presque jamais besoin de code. " + (auto ? "Ici il se lance dès l'ouverture du document." : "Ici rien ne dit qu'il se lance tout seul."),
                    ligne: "JavaScript : \(n) mention\(n > 1 ? "s" : "")" + (auto ? ", avec action à l'ouverture" : ""), categorie: .obfuscation)
        } else if auto { lignes.append("Action à l'ouverture : oui (sans JavaScript)") }
        if presents["lancement"] != nil {
            constat("pdf.lancement", .elevee, "PDF qui demande à lancer un programme", "L'action « Launch » fait ouvrir un programme ou un fichier par le lecteur de PDF.", ligne: "Lancement de programme (/Launch) : oui")
        }
        if presents["pièce jointe"] != nil {
            constat("pdf.piece-jointe", .faible, "PDF avec fichier joint", "Un fichier est rangé dans le PDF ; il n'a pas été extrait.", ligne: "Fichier joint (/EmbeddedFile) : oui")
        }
        if presents["envoi de formulaire"] != nil {
            constat("pdf.envoi", .faible, "PDF qui envoie un formulaire", "Le document peut envoyer ce qui est saisi vers un serveur.", ligne: "Envoi de formulaire (/SubmitForm) : oui", categorie: .reseau)
        }
        if presents["autre document"] != nil { lignes.append("Renvoi vers un autre document (/GoToR, /GoToE) : oui") }
        if presents["contenu riche"] != nil { lignes.append("Contenu riche ou formulaire XFA : oui") }
        if presents["chiffrement"] != nil {
            lignes.append("Document chiffré : oui")
            examen.nonAnalyse.append(NonAnalyse(fichier: chemin, raison: "PDF chiffré : son contenu ne peut pas être lu"))
        }
        for (i, script) in scripts.enumerated() where !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lignes.append("--- JavaScript n° \(i + 1) ---")
            lignes += script.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).prefix(2000).map { String($0.prefix(2000)) }
        }
        let liens = try! NSRegularExpression(pattern: #"/URI\s*\(((?:\\.|[^\\()])*)\)"#)
        let adresses = Set(liens.matches(in: corpus, range: etendue).prefix(500).map { (corpus as NSString).substring(with: $0.range(at: 1)) }).sorted()
        if !adresses.isEmpty {
            lignes.append("--- Liens du document (\(adresses.count)) ---")
            lignes += adresses.prefix(200).map { String($0.prefix(500)) }
        }
        examen.fiches.append(.fiche(fiche, lignes))
        examen.constats += constats
        return examen
    }

    // MARK: - Documents Office (conteneur OLE) et macros VBA

    /// Flux d'un conteneur OLE (ancien format Office, et `vbaProject.bin` des formats récents) : nom → contenu.
    static func fluxOLE(_ d: Data) -> [(nom: String, contenu: Data)]? {
        let octets = [UInt8](d)
        func u16(_ i: Int) -> Int { i + 1 < octets.count ? Int(octets[i]) | Int(octets[i + 1]) << 8 : 0 }
        func u32(_ i: Int) -> Int { i + 3 < octets.count ? u16(i) | u16(i + 2) << 16 : 0 }
        guard octets.count >= 512, Array(octets[0..<8]) == [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] else { return nil }
        let secteur = 1 << u16(30), petit = 1 << u16(32)
        guard secteur == 512 || secteur == 4096, petit == 64 else { return nil }
        let fin = 0xFFFF_FFFE, libre = 0xFFFF_FFFF, seuil = u32(56)
        func position(_ s: Int) -> Int { (s + 1) * secteur }
        // Table d'allocation : ses secteurs sont listés dans l'en-tête (109 premiers), puis dans une chaîne à part.
        var secteursFAT: [Int] = (0..<109).map { u32(76 + $0 * 4) }.filter { $0 < fin }
        var suivant = u32(68), garde = 0
        while suivant < fin, garde < 1000 {
            let p = position(suivant)
            for i in 0..<(secteur / 4 - 1) { let s = u32(p + i * 4); if s < fin { secteursFAT.append(s) } }
            suivant = u32(p + secteur - 4)
            garde += 1
        }
        var fat: [Int] = []
        for s in secteursFAT.prefix(20_000) { let p = position(s); for i in 0..<(secteur / 4) { fat.append(u32(p + i * 4)) } }
        func chaine(_ premier: Int, table: [Int], max: Int) -> [Int] {
            var liste: [Int] = [], s = premier
            while s < fin, s != libre, s < table.count, liste.count < max { liste.append(s); s = table[s] }
            return liste
        }
        func lire(_ premier: Int, taille: Int) -> Data {
            var r = Data()
            for s in chaine(premier, table: fat, max: taille / secteur + 2) {
                let p = position(s)
                guard p < octets.count else { break }
                r.append(contentsOf: octets[p..<min(p + secteur, octets.count)])
            }
            return r.prefix(taille)
        }
        let repertoire = [UInt8](lire(u32(48), taille: 4_000_000))
        var entrees: [(nom: String, type: UInt8, debut: Int, taille: Int)] = []
        var p = 0
        while p + 128 <= repertoire.count, entrees.count < 4000 {
            let longueur = min(64, Swift.max(0, Int(repertoire[p + 64]) | Int(repertoire[p + 65]) << 8) - 2)
            let nom = String(decoding: stride(from: 0, to: Swift.max(0, longueur), by: 2).map { UInt16(repertoire[p + $0]) | UInt16(repertoire[p + $0 + 1]) << 8 }, as: UTF16.self)
            func r32(_ i: Int) -> Int { Int(repertoire[p + i]) | Int(repertoire[p + i + 1]) << 8 | Int(repertoire[p + i + 2]) << 16 | Int(repertoire[p + i + 3]) << 24 }
            entrees.append((nom, repertoire[p + 66], r32(116), r32(120)))
            p += 128
        }
        guard let racine = entrees.first(where: { $0.type == 5 }) else { return nil }
        // Les petits flux sont rangés dans le flux de la racine, par blocs de 64 octets.
        let petits = [UInt8](lire(racine.debut, taille: min(racine.taille, 100_000_000)))
        let petiteTable = [UInt8](lire(u32(60), taille: u32(64) * secteur))
        let mini = stride(from: 0, to: petiteTable.count - 3, by: 4).map { Int(petiteTable[$0]) | Int(petiteTable[$0 + 1]) << 8 | Int(petiteTable[$0 + 2]) << 16 | Int(petiteTable[$0 + 3]) << 24 }
        var resultat: [(String, Data)] = []
        for e in entrees where e.type == 2 && e.taille > 0 && e.taille <= 50_000_000 {
            if e.taille < seuil {
                var r = Data()
                for s in chaine(e.debut, table: mini, max: e.taille / petit + 2) where (s + 1) * petit <= petits.count { r.append(contentsOf: petits[s * petit..<(s + 1) * petit]) }
                resultat.append((e.nom, r.prefix(e.taille)))
            } else { resultat.append((e.nom, lire(e.debut, taille: e.taille))) }
        }
        return resultat
    }

    /// Décompresse le texte d'un module VBA (format documenté par Microsoft, MS-OVBA 2.4.1). `depuis` : position de
    /// l'octet de signature 0x01. `premierBloc` : s'arrêter après un bloc (pour reconnaître un module à peu de frais).
    static func decompresserVBA(_ o: [UInt8], depuis: Int, premierBloc: Bool = false) -> [UInt8]? {
        guard depuis < o.count, o[depuis] == 0x01 else { return nil }
        var sortie: [UInt8] = [], p = depuis + 1
        while p + 1 < o.count, sortie.count < 20_000_000 {
            let entete = Int(o[p]) | Int(o[p + 1]) << 8
            guard entete & 0x7000 == 0x3000 else { return sortie.isEmpty ? nil : sortie }
            let finBloc = min(o.count, p + (entete & 0x0FFF) + 3), debutBloc = sortie.count
            p += 2
            if entete & 0x8000 == 0 {
                sortie.append(contentsOf: o[p..<min(o.count, p + 4096)])
                p = min(o.count, p + 4096)
            } else {
                while p < finBloc {
                    let drapeaux = o[p]
                    p += 1
                    for bit in 0..<8 where p < finBloc {
                        if drapeaux >> bit & 1 == 0 {
                            sortie.append(o[p])
                            p += 1
                        } else {
                            guard p + 1 < finBloc else { p = finBloc; break }
                            let jeton = Int(o[p]) | Int(o[p + 1]) << 8
                            p += 2
                            let ecart = sortie.count - debutBloc
                            var bits = 4
                            while 1 << bits < ecart, bits < 12 { bits += 1 }
                            let masque = 0xFFFF >> bits
                            let longueur = (jeton & masque) + 3, recul = (jeton >> (16 - bits)) + 1
                            guard recul <= sortie.count else { return sortie.isEmpty ? nil : sortie }
                            for _ in 0..<longueur { sortie.append(sortie[sortie.count - recul]) }
                        }
                    }
                }
            }
            p = finBloc
            if premierBloc { break }
        }
        return sortie
    }

    private static let lancementAuto = try! NSRegularExpression(
        pattern: #"\b(Auto_?Open|AutoExec|Auto_?Close|AutoNew|Document_Open|DocumentOpen|Document_Close|Document_New|Workbook_Open|Workbook_Activate|Workbook_BeforeClose|Worksheet_Activate)\b"#,
        options: [.caseInsensitive])
    private static let commandes = try! NSRegularExpression(
        pattern: #"\b(Shell|WScript\.Shell|CreateObject|GetObject|URLDownloadToFile|MSXML2|XMLHTTP|WinHttp|MacScript|AppleScriptTask|popen|ADODB\.Stream|CallByName|ShellExecute|powershell|cmd\.exe|Declare\s+(PtrSafe\s+)?(Function|Sub))\b"#,
        options: [.caseInsensitive])

    static func ole(_ donnees: Data, chemin: String) -> Examen {
        var examen = Examen()
        guard donnees.count <= tailleMax, let flux = fluxOLE(donnees) else {
            examen.nonAnalyse.append(NonAnalyse(fichier: chemin, raison: "document Office illisible ou de plus de 150 Mo"))
            return examen
        }
        let noms = flux.map(\.nom)
        var modules: [(nom: String, source: String)] = []
        for (nom, contenu) in flux where modules.count < 200 {
            let o = [UInt8](contenu)
            // Dans le flux d'un module, le texte compressé suit le code compilé : on cherche l'endroit où il commence.
            var p = 0, essais = 0
            while p + 2 < o.count, essais < 20_000 {
                if o[p] == 0x01, o[p + 2] & 0x70 == 0x30 {
                    essais += 1
                    if let debut = decompresserVBA(o, depuis: p, premierBloc: true), debut.starts(with: Array("Attribute VB_".utf8)),
                       let tout = decompresserVBA(o, depuis: p) {
                        modules.append((nom, String(data: Data(tout), encoding: .windowsCP1252) ?? String(decoding: tout, as: UTF8.self)))
                        break
                    }
                }
                p += 1
            }
        }
        let aDesMacros = !modules.isEmpty || noms.contains { $0 == "_VBA_PROJECT" || $0 == "PROJECT" }
        let fiche = "\(chemin) [macros]"
        var lignes = ["Fiche produite par Cerbère en lisant le document comme un fichier, sans l'ouvrir dans une app : ses macros. Le code ci-dessous est une donnée du document audité."]
        var constats: [Constat] = []
        func constat(_ regle: String, _ gravite: Gravite, _ titre: String, _ explication: String, ligne: Int?, extrait: String, categorie: Categorie = .obfuscation) {
            constats.append(Constat(id: "", gravite: gravite, statut: .suspect, categorie: categorie, titre: titre, fichier: aDesMacros && !modules.isEmpty ? fiche : chemin,
                                    lignes: ligne.map { [$0, $0] } ?? [], extrait: String(extrait.trimmingCharacters(in: .whitespaces).prefix(300)), explication: explication, origine: .regle, regle: regle))
        }
        if noms.contains("EncryptedPackage") {
            examen.nonAnalyse.append(NonAnalyse(fichier: chemin, raison: "document protégé par un mot de passe : contenu illisible"))
            constat("doc.chiffre", .faible, "Document protégé par un mot de passe", "Son contenu ne peut pas être lu. Un document piégé est parfois chiffré pour échapper aux antivirus, le mot de passe étant donné dans le message.",
                    ligne: nil, extrait: "EncryptedPackage", categorie: .autre)
        }
        if noms.contains(where: { $0.hasSuffix("Ole10Native") }) {
            constat("doc.objet", .moyenne, "Fichier embarqué dans le document", "Un fichier est rangé dans le document comme « objet » : un double-clic dessus l'ouvrirait.", ligne: nil, extrait: "Ole10Native", categorie: .autre)
        }
        guard aDesMacros else {
            examen.constats += constats
            return examen
        }
        var auto: (Int, String)?, commande: (Int, String)?
        for m in modules {
            lignes.append("--- Module \(m.nom) ---")
            for ligne in m.source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).prefix(5000) {
                let l = String(ligne.prefix(2000))
                lignes.append(l)
                // Les lignes « Attribute » sont écrites par Office, pas par l'auteur.
                guard !l.hasPrefix("Attribute ") else { continue }
                let etendue = NSRange(location: 0, length: (l as NSString).length)
                if auto == nil, lancementAuto.firstMatch(in: l, range: etendue) != nil { auto = (lignes.count, l) }
                if commande == nil, commandes.firstMatch(in: l, range: etendue) != nil { commande = (lignes.count, l) }
            }
        }
        if modules.isEmpty {
            examen.nonAnalyse.append(NonAnalyse(fichier: chemin, raison: "macros présentes, mais leur texte n'a pas pu être lu"))
            constat("doc.macros", .moyenne, "Document avec macros", "Le document contient du code (macros VBA) ; son texte n'a pas pu être lu.", ligne: nil, extrait: "_VBA_PROJECT")
        } else if let auto, let commande {
            constat("doc.macro-auto-commande", .critique, "Macro lancée à l'ouverture, qui lance des commandes",
                    "Le document lance son code dès l'ouverture (ou la fermeture), et ce code sait lancer des programmes ou télécharger : c'est la forme habituelle d'un document piégé.",
                    ligne: auto.0, extrait: auto.1)
            constat("doc.macro-commande", .moyenne, "Macro qui lance des commandes ou télécharge", "Cette ligne appelle une fonction qui sort du document (programme, script, téléchargement).", ligne: commande.0, extrait: commande.1)
        } else if let auto {
            constat("doc.macro-auto", .moyenne, "Macro lancée à l'ouverture", "Le document lance son code dès l'ouverture ou la fermeture, si les macros sont autorisées.", ligne: auto.0, extrait: auto.1)
        } else if let commande {
            constat("doc.macro-commande", .moyenne, "Macro qui lance des commandes ou télécharge", "Cette ligne appelle une fonction qui sort du document (programme, script, téléchargement).", ligne: commande.0, extrait: commande.1)
        } else {
            constat("doc.macros", .faible, "Document avec macros", "Le document contient du code (macros VBA). Rien n'y lance de commande ni ne démarre à l'ouverture.", ligne: 2, extrait: lignes.count > 1 ? lignes[1] : "")
        }
        if !modules.isEmpty { examen.fiches.append(.fiche(fiche, lignes)) }
        examen.constats += constats
        return examen
    }
}

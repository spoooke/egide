import Foundation

/// Ce qu'on a pu lire sur un reçu (capture, PDF PayPal ou PayByPhone, mail) pour pré-remplir la saisie.
struct BrouillonRecu: Equatable, Sendable {
    var centimes: Int?
    var date: Date?
    var commercant: String = ""
    var carte: String = ""
    /// Texte lu, pour classer la dépense quand le commerçant seul ne suffit pas (« Valve Corporation… Steam »).
    var texte: String = ""
}

/// Analyse du texte d'un reçu. Heuristiques simples, la saisie pré-remplie reste modifiable avant l'ajout.
enum Recu {
    static func analyser(_ texte: String, maintenant: Date = .now, calendrier: Calendar = .francais) -> BrouillonRecu {
        let lignes = texte.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return BrouillonRecu(centimes: montant(lignes),
                             date: date(lignes, maintenant: maintenant, calendrier: calendrier),
                             commercant: commercant(lignes),
                             carte: carte(lignes),
                             texte: String(lignes.joined(separator: " ").prefix(2_000)))
    }

    // MARK: Montant

    /// Montants d'une ligne : « 57,49 € », « 17,99 EUR », « € 2.40 », « EUR 1 234,50 ».
    static func montants(_ ligne: String) -> [Int] {
        let nombre = #"(\d{1,3}(?:[ .]\d{3})+|\d+)[,.](\d{2})(?!\d)"#
        let motifs = [nombre + #"\s*(?:€|EUR\b|euros?\b)"#, #"(?:€|EUR\b)\s*"# + nombre]
        var trouves: [(position: Int, centimes: Int)] = []
        for motif in motifs {
            guard let regex = try? NSRegularExpression(pattern: motif, options: [.caseInsensitive]) else { continue }
            let ns = ligne as NSString
            for m in regex.matches(in: ligne, range: NSRange(location: 0, length: ns.length)) {
                let euros = ns.substring(with: m.range(at: 1)).filter(\.isNumber)
                let cents = ns.substring(with: m.range(at: 2))
                if let e = Int(euros), let c = Int(cents) { trouves.append((m.range.location, e * 100 + c)) }
            }
        }
        return trouves.sorted { $0.position < $1.position }.map(\.centimes)
    }

    /// Le total payé : montant d'une ligne « Total / Montant / Payé… » (ou de la ligne suivante, l'OCR coupant
    /// parfois « Total » et le montant), sinon le montant le plus cité, puis le plus grand.
    static func montant(_ lignes: [String]) -> Int? {
        let motsCles = ["total ttc", "total payé", "montant total", "total", "montant payé", "montant", "payé", "paiement de",
                        "vous avez envoyé", "débité", "amount", "paid"]
        let normalisees = lignes.map { Classement.normaliser($0) }
        for motCle in motsCles.map(Classement.normaliser) {
            for (index, ligne) in normalisees.enumerated() where ligne.contains(motCle) && !ligne.contains("sous total") {
                if let m = montants(lignes[index]).last { return m }
                if index + 1 < lignes.count, montants(lignes[index + 1]).count == 1 { return montants(lignes[index + 1])[0] }
            }
        }
        let tous = lignes.flatMap(montants).filter { $0 > 0 }
        let comptes = Dictionary(tous.map { ($0, 1) }, uniquingKeysWith: +)
        return comptes.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key
    }

    // MARK: Date

    private static let moisFR = ["janvier", "fevrier", "mars", "avril", "mai", "juin", "juillet", "aout", "septembre",
                                 "octobre", "novembre", "decembre"]
    private static let moisEN = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// Première date plausible (pas dans le futur, moins d'un an) : « 7 octobre 2026 », « 07/10/2026 », « 2026-10-07 »,
    /// « Oct 7, 2026 ». Les lignes « acheté / payé / date » passent en premier.
    static func date(_ lignes: [String], maintenant: Date = .now, calendrier: Calendar = .francais) -> Date? {
        let prioritaires = lignes.filter { l in
            let n = Classement.normaliser(l)
            return ["achete", "paye", "date", "transaction", "effectue"].contains { n.contains($0) }
        }
        for ligne in prioritaires + lignes {
            for date in dates(ligne, calendrier: calendrier) {
                let ecart = date.timeIntervalSince(maintenant)
                if ecart < 86_400 && ecart > -366 * 86_400 { return date }
            }
        }
        return nil
    }

    static func dates(_ ligne: String, calendrier: Calendar = .francais) -> [Date] {
        let n = Classement.normaliser(ligne)
        var trouvees: [Date] = []
        func ajouter(_ j: Int?, _ m: Int?, _ a: Int?) {
            guard let j, let m, var a, (1...31).contains(j), (1...12).contains(m) else { return }
            if a < 100 { a += 2000 }
            // Midi : la date ne bascule pas d'un jour selon le fuseau.
            if let d = calendrier.date(from: DateComponents(year: a, month: m, day: j, hour: 12)) { trouvees.append(d) }
        }
        // 7 octobre 2026, 1er octobre 2026
        for m in correspondances(#"\b(\d{1,2})(?:er)? (janvier|fevrier|mars|avril|mai|juin|juillet|aout|septembre|octobre|novembre|decembre) (\d{4})\b"#, n) {
            ajouter(Int(m[1]), moisFR.firstIndex(of: m[2]).map { $0 + 1 }, Int(m[3]))
        }
        // oct 7 2026, october 7 2026
        for m in correspondances(#"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]* (\d{1,2}) (\d{4})\b"#, n) {
            ajouter(Int(m[2]), moisEN.firstIndex(of: m[1]).map { $0 + 1 }, Int(m[3]))
        }
        // 07/10/2026, 07.10.26, 07-10-2026 (jour en premier, à la française)
        for m in correspondances(#"\b(\d{1,2})[/.-](\d{1,2})[/.-](\d{4}|\d{2})\b"#, ligne) {
            ajouter(Int(m[1]), Int(m[2]), Int(m[3]))
        }
        // 2026-10-07
        for m in correspondances(#"\b(\d{4})-(\d{2})-(\d{2})\b"#, ligne) {
            ajouter(Int(m[3]), Int(m[2]), Int(m[1]))
        }
        return trouvees
    }

    // MARK: Commerçant et carte

    /// Commerçant : formule connue (« Merci d'avoir choisi X », « paiement à X », « Marchand : X »…),
    /// sinon la première ligne qui ressemble à un nom.
    static func commercant(_ lignes: [String]) -> String {
        let formules = [
            #"(?i)merci d['’]avoir choisi\s+(.+)"#,
            #"(?i)(?:paiement|payment)(?: de .+?)? (?:à|to)\s+(.+)"#,
            #"(?i)(?:paiement|payment) de [\d ,.]+ ?(?:€|EUR) a\s+(.+)"#,
            #"(?i)(?:marchand|commer[çc]ant|vendeur|b[ée]n[ée]ficiaire|merchant|seller)\s*:\s*(.+)"#,
            #"(?i)(?:votre )?re[çc]u (?:de |d['’])?(.+)"#,
            #"(?i)(?:receipt from|your receipt from)\s+(.+)"#,
            #"(?i)\bchez\s+(.+)"#,
        ]
        let texte = lignes.joined(separator: "\n")
        for formule in formules {
            if let m = correspondances(formule, texte).first {
                var nom = nettoyer(m[1])
                // Capture d'écran entière : la formule attrape parfois une autre ligne (« Voici votre reçu Dashlane »).
                for autre in formules {
                    if let interne = correspondances(autre, nom).first, !nettoyer(interne[1]).isEmpty { nom = nettoyer(interne[1]) }
                }
                if !nom.isEmpty { return nom }
            }
        }
        let ignorees = ["recu", "facture", "commande", "total", "merci", "bonjour", "date", "paiement", "montant", "invoice",
                        "receipt", "objet", "de ", "a ", "le "]
        for ligne in lignes.prefix(8) {
            // Barre d'état d'une capture d'iPhone (« 13:00 5G »).
            if ligne.range(of: #"^\s*\d{1,2}:\d{2}"#, options: .regularExpression) != nil { continue }
            // « État : accepté », « Réf. : 1234 » : un libellé, pas un nom (« Marchand : X » est lu plus haut).
            if ligne.range(of: #"^[^:]{1,20}\s:\s"#, options: .regularExpression) != nil { continue }
            let n = Classement.normaliser(ligne)
            guard n.count >= 3, n.count <= 40, n.contains(where: \.isLetter), montants(ligne).isEmpty,
                  dates(ligne).isEmpty, !ignorees.contains(where: { n.hasPrefix($0) }) else { continue }
            return nettoyer(ligne)
        }
        return ""
    }

    private static func nettoyer(_ nom: String) -> String {
        var nom = nom.components(separatedBy: CharacterSet(charactersIn: "\n.!,;(")).first ?? nom
        // « Valve Corporation pour 17,99 € » → « Valve Corporation »
        for coupe in [" pour ", " le ", " - ", " — ", " for ", " on ", " transaction", " date", " total"] {
            if let r = nom.range(of: coupe, options: .caseInsensitive) { nom = String(nom[..<r.lowerBound]) }
        }
        return String(nom.trimmingCharacters(in: .whitespaces).prefix(40))
    }

    /// « Visa 9321 », « Mastercard 1234 », « PayPal », ou vide.
    static func carte(_ lignes: [String]) -> String {
        let texte = lignes.joined(separator: " ")
        let n = Classement.normaliser(texte)
        let reseau = ["visa": "Visa", "mastercard": "Mastercard", "american express": "Amex", "amex": "Amex", "cb ": "CB"]
            .first { n.contains($0.key) }?.value
        let fin = correspondances(#"(?i)(?:[•·*xX]{2,}\s*|se terminant par\s*[•·*xX]*\s*|ending in\s*[•·*xX]*\s*)(\d{4})\b"#, texte).first?[1]
        if let fin { return [reseau ?? "Carte", fin].joined(separator: " ") }
        if n.contains("paypal") { return "PayPal" }
        if n.contains("apple pay") { return "Apple Pay" }
        return reseau ?? ""
    }

    // MARK: Outils

    /// Groupes capturés de chaque correspondance (indice 0 : toute la correspondance).
    private static func correspondances(_ motif: String, _ texte: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: motif) else { return [] }
        let ns = texte as NSString
        return regex.matches(in: texte, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }
}

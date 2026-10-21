import CryptoKit
import Foundation

/// Morceau de texte d'une ligne du relevé, avec sa position horizontale (points PDF, de gauche à droite).
struct MorceauReleve: Equatable, Sendable {
    var debut: Double
    var fin: Double
    var texte: String

    var milieu: Double { (debut + fin) / 2 }
}

/// Ligne du relevé : morceaux à la même hauteur, triés de gauche à droite.
struct LigneReleve: Equatable, Sendable {
    var morceaux: [MorceauReleve]

    var texte: String { morceaux.map(\.texte).joined(separator: " ") }
}

/// Page lue par position : lignes de haut en bas, milieu des titres de colonnes « Débit » et « Crédit ».
struct PageReleve: Equatable, Sendable {
    var lignes: [LigneReleve]
    var colonnes: Colonnes?

    struct Colonnes: Equatable, Sendable {
        var debit: Double
        var credit: Double
    }
}

/// Opération lue sur le relevé.
struct OperationReleve: Equatable, Sendable {
    enum Genre: Equatable, Sendable { case carte, retrait, prelevement, virement, autre }

    var dateOperation: Date
    var dateValeur: Date
    /// Libellé, une entrée par ligne du relevé (« CARTE X1234 05/09 COMMERCANT », « DE: … », « REF: … »).
    var lignes: [String]
    var centimes: Int
    var credit: Bool
    /// N° d'occurrence des opérations identiques (même date, montant, sens et libellé) sur le relevé.
    var rang: Int = 0

    var libelle: String { lignes.joined(separator: " ") }

    var genre: Genre {
        let premiere = Classement.normaliser(lignes.first ?? "")
        let mots = premiere.split(separator: " ")
        if mots.contains("retrait") { return .retrait }
        if mots.first == "carte" { return .carte }
        if mots.contains("prelevement") || mots.contains("prlv") || premiere.hasPrefix("echeance pret") { return .prelevement }
        if mots.contains("vir") || mots.contains("virement") { return .virement }
        return .autre
    }

    /// Jour de l'achat d'un paiement par carte (« CARTE X1234 05/09 … ») : la date comptable arrive 1 à 3 jours après.
    func dateAchat(calendrier: Calendar = .francais) -> Date? {
        guard genre == .carte, let m = Releve.correspondance(#"^CARTE\s+\S+\s+(?:[A-Z]+\s+)?(\d{2})/(\d{2})\b"#, lignes.first ?? ""),
              let jour = Int(m[1]), let mois = Int(m[2]) else { return nil }
        var annee = calendrier.component(.year, from: dateOperation)
        guard var date = calendrier.date(from: DateComponents(year: annee, month: mois, day: jour, hour: 12)) else { return nil }
        // Achat du 31/12 compté le 02/01.
        if date > dateOperation.addingTimeInterval(2 * 86_400) {
            annee -= 1
            date = calendrier.date(from: DateComponents(year: annee, month: mois, day: jour, hour: 12)) ?? date
        }
        return date
    }

    /// Nom du commerçant ou du tiers, sans « CARTE X1234 05/09 » ni l'intermédiaire (« PAYPAL * »).
    var commercant: String {
        let premiere = lignes.first ?? ""
        switch genre {
        case .carte:
            let nom = Releve.correspondance(#"^CARTE\s+\S+\s+(?:[A-Z]+\s+)?\d{2}/\d{2}\s+(.+)$"#, premiere)?[1] ?? premiere
            return Self.sansIntermediaire(nom)
        case .prelevement, .virement:
            for ligne in lignes.dropFirst() {
                if let m = Releve.correspondance(#"\b(?:DE|POUR)\s?:\s*(.+)$"#, ligne) {
                    return m[1].trimmingCharacters(in: .whitespaces)
                }
            }
            return premiere.replacingOccurrences(of: #"\s+\d{6,}$"#, with: "", options: .regularExpression)
        case .retrait, .autre:
            return premiere
        }
    }

    /// « PAYPAL *STEAMGAMES » → « STEAMGAMES », « SUMUP *CAFE DU PORT » → « CAFE DU PORT ».
    static func sansIntermediaire(_ nom: String) -> String {
        let intermediaires: Set<String> = ["paypal", "sumup", "sq", "zettle", "iz", "sp", "lydia", "stripe", "pp"]
        let parties = nom.split(separator: "*", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parties.count == 2, intermediaires.contains(Classement.normaliser(parties[0])), !parties[1].isEmpty {
            return parties[1]
        }
        return nom.replacingOccurrences(of: "*", with: " ").split(separator: " ").joined(separator: " ")
    }

    /// Identifiant stable de l'opération : empreinte de date | montant | sens | libellé normalisé | rang
    /// (rien de lisible du libellé n'est gardé).
    var id: String {
        let jour = Releve.jourISO(dateOperation)
        let cle = "\(jour)|\(centimes)|\(credit ? "C" : "D")|\(Classement.normaliser(libelle))|\(rang)"
        return SHA256.hash(data: Data(cle.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Relevé mensuel Société Générale lu par position : opérations, période, totaux imprimés.
struct Releve: Equatable, Sendable {
    var debut: Date
    var fin: Date
    var operations: [OperationReleve]
    var totalDebits: Int
    var totalCredits: Int

    enum Erreur: LocalizedError, Equatable {
        case pasUnReleve
        case totauxIntrouvables
        case totauxDifferents(debitsLus: Int, debitsImprimes: Int, creditsLus: Int, creditsImprimes: Int)

        var errorDescription: String? {
            switch self {
            case .pasUnReleve:
                "Ce PDF n'est pas un relevé de compte Société Générale lisible."
            case .totauxIntrouvables:
                "Totaux du relevé introuvables : impossible de vérifier la lecture, rien n'a été importé."
            case let .totauxDifferents(dl, di, cl, ci):
                "La lecture ne correspond pas aux totaux du relevé (débits lus \(Montant.texte(dl)) pour \(Montant.texte(di)), "
                    + "crédits lus \(Montant.texte(cl)) pour \(Montant.texte(ci))). Rien n'a été importé."
            }
        }
    }

    /// Lecture des pages : une opération commence par « JJ/MM/AAAA JJ/MM/AAAA » (date d'opération, date de valeur),
    /// son libellé continue sur les lignes suivantes, son montant est en fin de première ligne, dans la colonne
    /// « Débit » ou « Crédit ». La somme lue doit égaler les « TOTAUX DES MOUVEMENTS » imprimés.
    static func analyser(_ pages: [PageReleve], calendrier: Calendar = .francais) throws -> Releve {
        var periode: (Date, Date)?
        var operations: [OperationReleve] = []
        var totaux: (debits: Int, credits: Int)?
        var colonnes: PageReleve.Colonnes?
        /// Position du libellé de l'opération en cours (les lignes suivantes commencent au même endroit).
        var enCours: (operation: OperationReleve, x: Double)?

        func terminer() {
            if let enCours { operations.append(enCours.operation) }
            enCours = nil
        }

        pages: for page in pages {
            colonnes = page.colonnes ?? colonnes
            var dansLeTableau = false
            for ligne in page.lignes {
                let texte = ligne.texte
                let normalise = Classement.normaliser(texte)
                if periode == nil, let m = correspondance(#"\bdu (\d{2}/\d{2}/\d{4}) au (\d{2}/\d{2}/\d{4})"#, texte),
                   let d = date(m[1], calendrier), let f = date(m[2], calendrier) {
                    periode = (d, f)
                }
                if !dansLeTableau {
                    // En-tête « Date Valeur Nature de l'opération Débit Crédit » de chaque page.
                    dansLeTableau = normalise.hasPrefix("date valeur") && normalise.contains("debit") && normalise.contains("credit")
                    continue
                }
                guard let colonnes else { throw Erreur.pasUnReleve }
                // Hors des colonnes (texte vertical en marge) : ignoré.
                let morceaux = ligne.morceaux.filter { $0.debut < colonnes.credit + 40 }
                guard !morceaux.isEmpty else { continue }
                let montant = morceaux.last.flatMap { m -> (centimes: Int, credit: Bool)? in
                    guard m.milieu > colonnes.debit - 40, let c = centimes(m.texte) else { return nil }
                    return (c, abs(m.milieu - colonnes.credit) < abs(m.milieu - colonnes.debit))
                }
                if normalise.contains("totaux des mouvements") {
                    terminer()
                    var debits = 0, credits = 0
                    for m in morceaux where m.milieu > colonnes.debit - 40 {
                        guard let c = centimes(m.texte) else { continue }
                        if abs(m.milieu - colonnes.credit) < abs(m.milieu - colonnes.debit) { credits = c } else { debits = c }
                    }
                    totaux = (debits, credits)
                    break pages
                }
                if normalise.hasPrefix("suite") || texte.contains(">>>") { terminer(); continue pages }
                if normalise.contains("solde") && (texte.contains("***") || normalise.contains("solde precedent")
                                                   || normalise.contains("nouveau solde")) {
                    terminer()
                    continue
                }
                if let m = correspondance(#"^(\d{2}/\d{2}/\d{4}) (\d{2}/\d{2}/\d{4})\b"#, texte),
                   let operation = date(m[1], calendrier), let valeur = date(m[2], calendrier) {
                    terminer()
                    guard let montant else { continue }
                    // Libellé : morceaux entre les dates et le montant.
                    let libelle = morceaux.dropLast().filter { correspondance(#"^\d{2}/\d{2}/\d{4}$"#, $0.texte) == nil }
                    var debutLibelle = libelle.map(\.texte).joined(separator: " ")
                    if libelle.isEmpty || libelle.first?.texte.hasPrefix(m[0]) == true {
                        // Dates et libellé dans un même morceau.
                        debutLibelle = String(texte.dropFirst(m[0].count))
                        if let fin = morceaux.last?.texte, debutLibelle.hasSuffix(fin) { debutLibelle = String(debutLibelle.dropLast(fin.count)) }
                    }
                    let x = libelle.first?.debut ?? morceaux[0].debut
                    enCours = (OperationReleve(dateOperation: operation, dateValeur: valeur,
                                               lignes: [debutLibelle.trimmingCharacters(in: .whitespaces)],
                                               centimes: montant.centimes, credit: montant.credit), x)
                    continue
                }
                // Suite du libellé : même colonne, pas de montant.
                if var courant = enCours, montant == nil, abs(morceaux[0].debut - courant.x) < 30 {
                    courant.operation.lignes.append(texte.trimmingCharacters(in: .whitespaces))
                    enCours = courant
                } else {
                    terminer()
                }
            }
            terminer()
        }
        terminer()

        guard let periode, !operations.isEmpty else { throw Erreur.pasUnReleve }
        guard let totaux else { throw Erreur.totauxIntrouvables }
        let debits = operations.filter { !$0.credit }.reduce(0) { $0 + $1.centimes }
        let credits = operations.filter(\.credit).reduce(0) { $0 + $1.centimes }
        guard debits == totaux.debits, credits == totaux.credits else {
            throw Erreur.totauxDifferents(debitsLus: debits, debitsImprimes: totaux.debits,
                                          creditsLus: credits, creditsImprimes: totaux.credits)
        }
        // Rang des opérations identiques, pour que deux cafés du même jour aient chacun leur identifiant.
        var vus: [String: Int] = [:]
        for index in operations.indices {
            let o = operations[index]
            let cle = "\(jourISO(o.dateOperation))|\(o.centimes)|\(o.credit)|\(Classement.normaliser(o.libelle))"
            operations[index].rang = vus[cle, default: 0]
            vus[cle, default: 0] += 1
        }
        return Releve(debut: periode.0, fin: periode.1, operations: operations, totalDebits: totaux.debits,
                      totalCredits: totaux.credits)
    }

    // MARK: Outils

    /// « 1.234,56 », « 9,99 », « + 1.234,56 » → centimes.
    static func centimes(_ texte: String) -> Int? {
        guard let m = correspondance(#"^[+-]?\s?(\d{1,3}(?:\.\d{3})*),(\d{2})$"#, texte.trimmingCharacters(in: .whitespaces)),
              let euros = Int(m[1].replacingOccurrences(of: ".", with: "")), let cents = Int(m[2]) else { return nil }
        return euros * 100 + cents
    }

    /// « 05/09/2026 » → 5 septembre 2026 à midi (la date ne bascule pas selon le fuseau).
    static func date(_ texte: String, _ calendrier: Calendar = .francais) -> Date? {
        let p = texte.split(separator: "/").compactMap { Int($0) }
        guard p.count == 3, (1...31).contains(p[0]), (1...12).contains(p[1]) else { return nil }
        return calendrier.date(from: DateComponents(year: p[2], month: p[1], day: p[0], hour: 12))
    }

    static func jourISO(_ date: Date, calendrier: Calendar = .francais) -> String {
        let c = calendrier.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Groupes capturés de la première correspondance (indice 0 : toute la correspondance).
    static func correspondance(_ motif: String, _ texte: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: motif),
              let m = regex.firstMatch(in: texte, range: NSRange(texte.startIndex..., in: texte)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: texte).map { String(texte[$0]) } ?? ""
        }
    }
}

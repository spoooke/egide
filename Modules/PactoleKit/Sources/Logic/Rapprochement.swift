import Foundation
import SwiftData

/// Rapprochement du relevé avec les dépenses déjà saisies (docs/money-synchro-bancaire.md, section 4) :
/// - opération déjà vue (journal ou dépense qui porte son identifiant) : rien ;
/// - retrait d'espèces : ignoré (ce qu'on en fait est saisi à la main, source Espèces) ;
/// - frais fixe mensuel actif (libellé appris ou nom du frais, montant à 10 % près ou somme de plusieurs opérations ;
///   sinon prélèvement du même montant à 5 jours du jour prévu) : ignoré, déjà compté à part ;
/// - frais annuel retrouvé par son libellé : dépense du jour, en Imprévu (hors plafond de la semaine) ;
/// - dépense existante non rapprochée, toutes sources, même montant au centime, au jour d'achat ±1 j
///   (sinon date comptable −4 j…0), le commerçant départageant : 1 candidate → liée, plusieurs → « À vérifier » ;
/// - aucune : nouvelle dépense « Banque » classée par les règles ;
/// - crédit : proposé comme revenu du mois de l'opération (salaire reconnu, le reste à confirmer).
@MainActor
enum Rapprochement {
    enum Issue: Equatable {
        case dejaVue
        case retrait
        case fraisFixe(nom: String)
        case liee(Depense)
        /// Plusieurs dépenses possibles : la plus proche en date est liée et passe dans « À vérifier ».
        case aVerifier(Depense, candidates: Int)
        case nouvelle(posteID: String, aVerifier: Bool)
        case revenu
    }

    struct Ligne: Identifiable {
        let operation: OperationReleve
        let issue: Issue
        var id: String { operation.id }
    }

    struct PropositionRevenu: Identifiable, Equatable {
        let operation: OperationReleve
        var libelle: String
        var retenu: Bool
        /// Reconnu comme salaire (mot du libellé ou tiers déjà retenu comme salaire).
        let salaire: Bool
        /// Un revenu du même montant existe déjà ce mois-là (saisi à la main).
        let dejaSaisi: Bool
        var id: String { operation.id }
        var mois: String { Revenu.cle(operation.dateOperation) }
    }

    struct Plan {
        let releve: Releve
        let lignes: [Ligne]
        var revenus: [PropositionRevenu]

        func nombre(_ filtre: (Issue) -> Bool) -> Int { lignes.filter { filtre($0.issue) }.count }
    }

    struct Bilan: Equatable {
        var liees = 0, nouvelles = 0, aVerifier = 0, ignorees = 0, revenus = 0
    }

    enum Erreur: LocalizedError, Equatable {
        case dejaAjoute(le: Date)

        var errorDescription: String? {
            switch self {
            case .dejaAjoute(let date):
                "Ce relevé a déjà été ajouté le " + date.formatted(Date.FormatStyle(locale: Locale(identifier: "fr_FR")).day().month(.wide).year())
                    + " : rien n'est importé deux fois."
            }
        }
    }

    /// Tiers dont un crédit a été retenu comme « Salaire » (reconnu aux relevés suivants).
    static var tiersSalaire: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "money.tiersSalaire") ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: "money.tiersSalaire") }
    }

    // MARK: Préparation (rien n'est modifié)

    static func preparer(_ releve: Releve, dans context: ModelContext, calendrier: Calendar = .francais) throws -> Plan {
        if let deja = try context.fetch(FetchDescriptor<ReleveAjoute>()).first(where: {
            Releve.jourISO($0.debut) == Releve.jourISO(releve.debut) && Releve.jourISO($0.fin) == Releve.jourISO(releve.fin)
        }) {
            throw Erreur.dejaAjoute(le: deja.ajouteLe)
        }
        let depenses = try context.fetch(FetchDescriptor<Depense>())
        var vues = Set(try context.fetch(FetchDescriptor<OperationVue>()).map(\.banqueID))
        vues.formUnion(depenses.map(\.banqueID).filter { !$0.isEmpty })
        let frais = try context.fetch(FetchDescriptor<FraisFixe>()).filter(\.actif)
        let revenus = try context.fetch(FetchDescriptor<Revenu>())
        let regles = try context.fetch(FetchDescriptor<Regle>()).map { ($0.motif, $0.posteID) }
        let connus = Set(depenses.filter { !$0.aVerifier && !$0.commercant.isEmpty }.map { Classement.normaliser($0.commercant) })
        // Salaire déjà saisi (même mois, même montant, libellé « Salaire … ») : son émetteur est retenu, pour reconnaître
        // le salaire des mois suivants même sans le mot « salaire » dans le virement.
        var salaires = tiersSalaire
        for op in releve.operations where op.credit {
            if revenus.contains(where: { estLibelleSalaire($0.libelle) && $0.mois == Revenu.cle(op.dateOperation)
                                         && $0.montantCentimes == op.centimes }) {
                let nom = Classement.normaliser(op.commercant)
                if !nom.isEmpty { salaires.insert(nom) }
            }
        }
        if salaires != tiersSalaire { tiersSalaire = salaires }
        let libelleSalaire = revenus.filter { estLibelleSalaire($0.libelle) }.max { $0.mois < $1.mois }?.libelle ?? "Salaire"

        var issues: [Int: Issue] = [:]
        var propositions: [PropositionRevenu] = []
        var aRapprocher: [Int] = []
        for (index, op) in releve.operations.enumerated() {
            if vues.contains(op.id) {
                issues[index] = .dejaVue
            } else if op.credit {
                issues[index] = .revenu
                let salaire = estSalaire(op, tiers: salaires)
                let dejaSaisi = revenus.contains { $0.mois == Revenu.cle(op.dateOperation) && $0.montantCentimes == op.centimes }
                propositions.append(PropositionRevenu(operation: op, libelle: salaire ? libelleSalaire : libelleRevenu(op),
                                                      retenu: salaire && !dejaSaisi, salaire: salaire, dejaSaisi: dejaSaisi))
            } else if op.genre == .retrait {
                issues[index] = .retrait
            } else {
                aRapprocher.append(index)
            }
        }
        for (index, f) in fraisFixes(releve.operations, indices: aRapprocher, frais: frais, calendrier: calendrier) {
            issues[index] = .fraisFixe(nom: f.nom)
        }
        // Frais annuel (rappel) : son paiement est une dépense du jour, hors plafond de la semaine.
        for index in aRapprocher where issues[index] == nil {
            if frais.contains(where: { $0.annuel && reconnu(releve.operations[index], $0) }) {
                issues[index] = .nouvelle(posteID: Poste.imprevu, aVerifier: false)
            }
        }
        aRapprocher.removeAll { issues[$0] != nil }

        // Candidates de chaque opération, puis attribution : d'abord les cas sans ambiguïté (une seule candidate,
        // ou une seule au même commerçant), répétée tant qu'elle avance, pour que deux opérations identiques
        // se partagent deux dépenses identiques.
        let libres = depenses.filter { $0.banqueID.isEmpty && $0.source != .banque }
        var candidates: [Int: [Depense]] = [:]
        for index in aRapprocher {
            let op = releve.operations[index]
            let fenetre = fenetre(op, calendrier: calendrier)
            candidates[index] = libres.filter {
                $0.montantCentimes == op.centimes && fenetre.contains(calendrier.startOfDay(for: $0.date))
            }
        }
        var prises = Set<PersistentIdentifier>()
        var avance = true
        while avance {
            avance = false
            for index in aRapprocher where issues[index] == nil {
                let restantes = (candidates[index] ?? []).filter { !prises.contains($0.persistentModelID) }
                guard !restantes.isEmpty else { continue }
                let nom = Classement.normaliser(releve.operations[index].commercant)
                let memeCommercant = restantes.filter { commercantProche(nom, $0) }
                guard let choisie = restantes.count == 1 ? restantes[0] : (memeCommercant.count == 1 ? memeCommercant[0] : nil)
                else { continue }
                issues[index] = .liee(choisie)
                prises.insert(choisie.persistentModelID)
                avance = true
            }
        }
        // Restent les doutes. Des opérations identiques face à autant de dépenses identiques (deux tabacs le même jour)
        // sont liées sans doute : peu importe laquelle va avec laquelle.
        let initiales = candidates.mapValues { Set($0.map(\.persistentModelID)) }
        let doutes = aRapprocher.filter { issues[$0] == nil }
        for index in doutes {
            let op = releve.operations[index]
            let restantes = (candidates[index] ?? []).filter { !prises.contains($0.persistentModelID) }
            let reference = op.dateAchat(calendrier: calendrier) ?? op.dateOperation
            if let proche = restantes.min(by: { abs($0.date.timeIntervalSince(reference)) < abs($1.date.timeIntervalSince(reference)) }) {
                let jumelles = doutes.filter { initiales[$0] == initiales[index] }.count
                issues[index] = jumelles >= (initiales[index]?.count ?? 0)
                    ? .liee(proche) : .aVerifier(proche, candidates: restantes.count)
                prises.insert(proche.persistentModelID)
            } else {
                let classement = Classement.classer(commercant: op.commercant, centimes: op.centimes, regles: regles,
                                                    commercantsConnus: connus)
                issues[index] = .nouvelle(posteID: classement.posteID, aVerifier: classement.aVerifier)
            }
        }
        let lignes = releve.operations.enumerated().map { Ligne(operation: $1, issue: issues[$0] ?? .dejaVue) }
        return Plan(releve: releve, lignes: lignes, revenus: propositions)
    }

    // MARK: Import

    /// Applique le plan : liens, nouvelles dépenses, revenus retenus, journal des opérations vues, relevé ajouté.
    @discardableResult
    static func appliquer(_ plan: Plan, dans context: ModelContext, maintenant: Date = .now) throws -> Bilan {
        var bilan = Bilan()
        let ajoute = ReleveAjoute(debut: plan.releve.debut, fin: plan.releve.fin, operations: plan.releve.operations.count)
        ajoute.ajouteLe = maintenant
        for ligne in plan.lignes {
            let op = ligne.operation
            let vue = OperationVue(banqueID: op.id, releve: ajoute.cle)
            switch ligne.issue {
            case .dejaVue, .revenu:
                continue
            case .retrait, .fraisFixe:
                bilan.ignorees += 1
            case .liee(let depense):
                depense.banqueID = op.id
                depense.modifiedAt = maintenant
                vue.lieeID = depense.syncID
                bilan.liees += 1
            case .aVerifier(let depense, _):
                depense.banqueID = op.id
                depense.aVerifier = true
                depense.modifiedAt = maintenant
                vue.lieeID = depense.syncID
                bilan.aVerifier += 1
            case let .nouvelle(posteID, aVerifier):
                let depense = Depense(montantCentimes: op.centimes, posteID: posteID, date: op.dateAchat() ?? op.dateOperation,
                                      source: .banque)
                depense.commercant = op.commercant
                depense.banqueID = op.id
                depense.aVerifier = aVerifier
                depense.createdAt = maintenant
                depense.modifiedAt = maintenant
                context.insert(depense)
                vue.creeID = depense.syncID
                bilan.nouvelles += 1
            }
            context.insert(vue)
        }
        var salaires = tiersSalaire
        for proposition in plan.revenus {
            let libelle = proposition.libelle.trimmingCharacters(in: .whitespaces)
            let vue = OperationVue(banqueID: proposition.operation.id, releve: ajoute.cle)
            if proposition.retenu, !libelle.isEmpty {
                let revenu = Revenu(mois: proposition.mois, libelle: libelle, montantCentimes: proposition.operation.centimes)
                context.insert(revenu)
                vue.creeID = revenu.syncID
                bilan.revenus += 1
                if estLibelleSalaire(libelle) {
                    salaires.insert(Classement.normaliser(proposition.operation.commercant))
                }
            }
            // Retenu ou non, le crédit ne sera plus proposé.
            context.insert(vue)
        }
        tiersSalaire = salaires
        context.insert(ajoute)
        try context.save()
        return bilan
    }

    /// Annule l'import d'un relevé : dépenses et revenus qu'il a créés supprimés, dépenses existantes déliées,
    /// opérations oubliées. Le relevé peut ensuite être ajouté de nouveau.
    static func annuler(_ releve: ReleveAjoute, dans context: ModelContext) throws {
        let cle = releve.cle
        let vues = try context.fetch(FetchDescriptor<OperationVue>()).filter {
            // Imports d'avant ce suivi : opérations vues dans les deux minutes de l'ajout du relevé.
            $0.releve == cle || ($0.releve.isEmpty && abs($0.vueLe.timeIntervalSince(releve.ajouteLe)) < 120)
        }
        let ids = Set(vues.map(\.banqueID))
        let crees = Set(vues.map(\.creeID).filter { !$0.isEmpty })
        for depense in try context.fetch(FetchDescriptor<Depense>()) {
            if crees.contains(depense.syncID) || (depense.source == .banque && ids.contains(depense.banqueID)) {
                Suppressions.supprimer(depense, dans: context)
            } else if ids.contains(depense.banqueID) {
                depense.banqueID = ""
                depense.modifiedAt = .now
            }
        }
        for revenu in try context.fetch(FetchDescriptor<Revenu>()) where crees.contains(revenu.syncID) {
            Suppressions.supprimer(revenu, dans: context)
        }
        vues.forEach(context.delete)
        context.delete(releve)
        try context.save()
    }

    // MARK: Frais fixes rattachés à la main

    /// « C'est le frais fixe X » : la dépense importée du relevé est un frais déjà compté à part. Son libellé est retenu
    /// pour reconnaître ce frais aux relevés suivants. Mensuel : la dépense est supprimée ; annuel : elle reste
    /// (paiement du jour), en Imprévu, hors plafond de la semaine.
    static func rattacher(_ depense: Depense, a frais: FraisFixe, dans context: ModelContext) throws {
        let motif = Classement.normaliser(depense.commercant)
        if !motif.isEmpty, !motifs(frais).contains(motif) {
            frais.motifBanque = (motifs(frais) + [motif]).joined(separator: "|")
            frais.modifiedAt = .now
        }
        if frais.annuel {
            depense.posteID = Poste.imprevu
            depense.aVerifier = false
            depense.modifiedAt = .now
        } else {
            Suppressions.supprimer(depense, dans: context)
        }
        try context.save()
    }

    /// Nouveau frais fixe (mensuel, ou annuel dans le mois de la dépense) créé depuis une dépense du relevé.
    @discardableResult
    static func nouveauFrais(depuis depense: Depense, annuel: Bool, dans context: ModelContext,
                             calendrier: Calendar = .francais) throws -> FraisFixe {
        let nom = depense.commercant.isEmpty ? "Frais" : depense.commercant.capitalized
        let frais = FraisFixe(nom: nom, montantCentimes: depense.montantCentimes,
                              jour: calendrier.component(.day, from: depense.date), categorie: annuel ? .autre : .abonnement)
        if annuel { frais.moisAnnuel = calendrier.component(.month, from: depense.date) }
        context.insert(frais)
        try rattacher(depense, a: frais, dans: context)
        return frais
    }

    static func motifs(_ frais: FraisFixe) -> [String] {
        frais.motifBanque.split(separator: "|").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: Sens inverse

    /// Dépense « Banque » déjà importée qui correspond à un paiement saisi après coup (Apple Pay, reçu partagé tard) :
    /// même montant, datée du jour du paiement (achat par carte, ±1 j) ou jusqu'à 4 jours après (date comptable).
    static func depenseDuReleve(centimes: Int, date: Date, parmi depenses: [Depense],
                                calendrier: Calendar = .francais) -> Depense? {
        let jour = calendrier.startOfDay(for: date)
        func ecart(_ d: Depense) -> Int {
            calendrier.dateComponents([.day], from: jour, to: calendrier.startOfDay(for: d.date)).day ?? 99
        }
        // Une dépense déjà complétée (carte connue) passe après : deux achats identiques le même jour.
        return depenses
            .filter { $0.source == .banque && !$0.banqueID.isEmpty && $0.montantCentimes == centimes && (-1...4).contains(ecart($0)) }
            .min { ($0.carte.isEmpty ? 0 : 1, abs(ecart($0))) < ($1.carte.isEmpty ? 0 : 1, abs(ecart($1))) }
    }

    // MARK: Outils

    /// Jours où chercher la dépense : jour d'achat ±1 j pour une carte, sinon date comptable −4 j…0.
    static func fenetre(_ op: OperationReleve, calendrier: Calendar = .francais) -> ClosedRange<Date> {
        func jour(_ d: Date, _ decalage: Int) -> Date {
            calendrier.startOfDay(for: calendrier.date(byAdding: .day, value: decalage, to: d) ?? d)
        }
        if let achat = op.dateAchat(calendrier: calendrier) { return jour(achat, -1)...jour(achat, 1) }
        return jour(op.dateOperation, -4)...jour(op.dateOperation, 0)
    }

    /// Comment l'opération est reconnue comme ce frais : par un libellé que d'autres frais partagent (Apple : Lightroom,
    /// iCloud+…), ou par un libellé ou un nom propre à ce frais.
    enum Reconnaissance { case partagee, propre }

    /// Libellés différents d'un même prestataire selon les mois.
    private static let alias: [[String]] = [["itunesappst appl", "apple com bill"]]

    /// Libellé de l'opération où l'on retrouve ce frais : un libellé appris, le premier mot de son nom
    /// (« Netflix (2 abonnements) » → « netflix »), ou un mot distinctif d'au moins 6 lettres, même tronqué par la banque
    /// ou collé à un autre (« Prêts Franfinance » et « SOGEFINANC.EXPRESSO-FRANFINANC », « YouTube » et « YouTubePremium »).
    static func reconnaissance(_ op: OperationReleve, _ frais: FraisFixe, motifsPartages: Set<String> = []) -> Reconnaissance? {
        var libelle = " \(Classement.normaliser(op.libelle)) "
        for groupe in alias where groupe.contains(where: { a in libelle.contains(" \(a) ") }) {
            libelle += groupe.joined(separator: " ") + " "
        }
        let trouves = motifs(frais).filter { motif in libelle.contains(" \(motif) ") }
        if trouves.contains(where: { m in !partage(m, motifsPartages) }) { return .propre }
        let sansParentheses = frais.nom.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
        let mots = Classement.normaliser(sansParentheses).split(separator: " ").map(String.init)
        if let premier = mots.first(where: { $0.count >= 3 }), libelle.contains(" \(premier) ") { return .propre }
        let distinctifs = mots.filter { $0.count >= 6 && !motsCourants.contains($0) }
        let motsDuLibelle = libelle.split(separator: " ").map(String.init).filter { $0.count >= 6 }
        if distinctifs.contains(where: { mot in motsDuLibelle.contains { mot.hasPrefix($0) || $0.hasPrefix(mot) } }) { return .propre }
        return trouves.isEmpty ? nil : .partagee
    }

    static func reconnu(_ op: OperationReleve, _ frais: FraisFixe) -> Bool { reconnaissance(op, frais) != nil }

    /// Un libellé (ou l'un de ses alias) appris par plusieurs frais.
    private static func partage(_ motif: String, _ partages: Set<String>) -> Bool {
        let groupe = alias.first { $0.contains(motif) } ?? [motif]
        return groupe.contains { partages.contains($0) }
    }

    /// Mots trop courants pour reconnaître un frais à eux seuls.
    private static let motsCourants: Set<String> = [
        "assurance", "assurances", "abonnement", "abonnements", "systemes", "energetiques", "premium", "mobile", "cotisation",
        "credit", "credits", "telecom", "prelevement", "europeen", "electronique", "commerce", "mensuel", "mensualite",
    ]

    /// Opérations du relevé qui sont des frais fixes mensuels, au plus une fois par frais et par mois :
    /// 1. libellé reconnu, montant le plus proche à 10 % près (prix qui bouge, devise), 50 % pour un nom ou un libellé
    ///    propre à ce frais (le prix a changé depuis : relevés anciens) ;
    ///    sinon plusieurs opérations reconnues dont la somme fait le montant (« Netflix (2 abonnements) ») ;
    /// 2. prélèvement (pas une carte ni un frais de la banque) du même montant (1 %) à 5 jours du jour prévu.
    static func fraisFixes(_ ops: [OperationReleve], indices: [Int], frais: [FraisFixe],
                           calendrier: Calendar = .francais) -> [Int: FraisFixe] {
        let mensuels = frais.filter { $0.actif && !$0.annuel }.sorted { $0.nom < $1.nom }
        var resultat: [Int: FraisFixe] = [:]
        var pris = Set<String>() // syncID du frais | mois
        func ecart(_ centimes: Int, _ f: FraisFixe) -> Double {
            Double(abs(centimes - f.montantCentimes)) / Double(max(f.montantCentimes, 1))
        }
        // Libellés appris par plusieurs frais (Apple), alias compris.
        var compte: [String: Int] = [:]
        for f in mensuels {
            Set(motifs(f).flatMap { m in alias.first { $0.contains(m) } ?? [m] }).forEach { compte[$0, default: 0] += 1 }
        }
        let partages = Set(compte.filter { $0.value > 1 }.keys)
        // Les frais reconnus par un libellé propre passent avant ceux d'un libellé partagé.
        let ordre = mensuels.sorted { a, b in
            let pa = motifs(a).contains { partage($0, partages) }, pb = motifs(b).contains { partage($0, partages) }
            return pa != pb ? !pa : a.nom < b.nom
        }
        for f in ordre {
            var tolerance: [Int: Double] = [:]
            for i in indices where resultat[i] == nil {
                if let r = reconnaissance(ops[i], f, motifsPartages: partages) { tolerance[i] = r == .propre ? 0.5 : 0.1 }
            }
            let reconnues = tolerance.keys.sorted()
            for (mois, groupe) in Dictionary(grouping: reconnues, by: { Revenu.cle(ops[$0].dateOperation, calendrier: calendrier) }) {
                let proche = groupe.min { ecart(ops[$0].centimes, f) < ecart(ops[$1].centimes, f) }!
                // D'abord le montant (10 %), puis la somme de plusieurs opérations, enfin l'ancien prix (nom propre au frais).
                if ecart(ops[proche].centimes, f) <= 0.1 {
                    resultat[proche] = f
                } else if case let propres = groupe.filter({ tolerance[$0]! > 0.1 }), propres.count >= 2,
                          ecart(propres.reduce(0) { $0 + ops[$1].centimes }, f) <= 0.1 {
                    // Somme : seulement des opérations propres à ce frais (pas un achat Apple quelconque).
                    propres.forEach { resultat[$0] = f }
                } else if ecart(ops[proche].centimes, f) <= tolerance[proche]! {
                    resultat[proche] = f
                } else {
                    continue
                }
                pris.insert(f.syncID + "|" + mois)
            }
        }
        for i in indices where resultat[i] == nil && ops[i].genre == .prelevement {
            let op = ops[i]
            let mois = Revenu.cle(op.dateOperation, calendrier: calendrier)
            let jour = calendrier.component(.day, from: op.dateOperation)
            if let f = mensuels.first(where: { f in
                let e = abs(jour - f.jour)
                return !pris.contains(f.syncID + "|" + mois) && ecart(op.centimes, f) <= 0.01 && min(e, 31 - e) <= 5
            }) {
                resultat[i] = f
                pris.insert(f.syncID + "|" + mois)
            }
        }
        return resultat
    }

    /// Commerçant du relevé et d'une dépense : même nom (`Paiements.memeCommercant`) ou un mot d'au moins 4 lettres en commun
    /// (« LECLERC ORLEANS » et « E.Leclerc »).
    static func commercantProche(_ nom: String, _ depense: Depense) -> Bool {
        let autre = Classement.normaliser(depense.commercant.isEmpty ? depense.note : depense.commercant)
        if Paiements.memeCommercant(nom, autre) { return true }
        let mots = Set(nom.split(separator: " ").filter { $0.count >= 4 })
        return autre.split(separator: " ").contains { mots.contains($0) }
    }

    static func estSalaire(_ op: OperationReleve, tiers: Set<String>) -> Bool {
        let mots = Set(Classement.normaliser(op.libelle).split(separator: " "))
        if !mots.isDisjoint(with: ["salaire", "salaires", "paie", "remuneration"]) { return true }
        let nom = Classement.normaliser(op.commercant)
        return !nom.isEmpty && tiers.contains(nom)
    }

    /// « Salaire », « Salaire SARL Martin ».
    static func estLibelleSalaire(_ libelle: String) -> Bool {
        Classement.normaliser(libelle).split(separator: " ").contains("salaire")
    }

    private static func libelleRevenu(_ op: OperationReleve) -> String {
        if op.genre == .carte { return "Remboursement \(op.commercant)" }
        let nom = op.commercant.trimmingCharacters(in: .whitespaces)
        return nom.isEmpty ? "Virement reçu" : nom
    }
}

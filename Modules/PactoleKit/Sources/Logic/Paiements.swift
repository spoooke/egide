import Foundation
import SwiftData

/// Enregistrement des paiements Apple Pay (action Raccourcis) et de la lecture de secours de transactions.csv.
@MainActor
enum Paiements {
    enum Resultat: Equatable {
        case ajoutee(posteID: String, aVerifier: Bool)
        case doublon
        /// Déjà importé du relevé bancaire : la dépense « Banque » est complétée (commerçant, carte, poste).
        case rapprochee(posteID: String, aVerifier: Bool)
    }

    enum Erreur: LocalizedError {
        case montantInvalide(String)

        var errorDescription: String? {
            switch self {
            case .montantInvalide(let texte): "Montant illisible : « \(texte) »."
            }
        }
    }

    /// Ajoute un paiement, classé automatiquement, sauf s'il est déjà enregistré
    /// (même jour, même montant, même commerçant, y compris une dépense reprise du Suivi hebdo).
    /// Déjà arrivé par le relevé bancaire : la dépense « Banque » est complétée au lieu d'en créer une seconde.
    static func ajouter(commercant: String, centimes: Int, carte: String, date: Date,
                        source: SourceDepense = .applePay, dans context: ModelContext) throws -> Resultat {
        let depenses = try context.fetch(FetchDescriptor<Depense>())
        let regles = try context.fetch(FetchDescriptor<Regle>()).map { ($0.motif, $0.posteID) }
        let connus = Set(depenses.filter { !$0.aVerifier && !$0.commercant.isEmpty }.map { Classement.normaliser($0.commercant) })
        let classement = Classement.classer(commercant: commercant, centimes: centimes, regles: regles, commercantsConnus: connus)

        if let releve = Rapprochement.depenseDuReleve(centimes: centimes, date: date, parmi: depenses) {
            releve.commercant = commercant.trimmingCharacters(in: .whitespaces)
            releve.carte = carte.trimmingCharacters(in: .whitespaces)
            // Le nom Wallet classe souvent mieux que le libellé bancaire.
            if releve.aVerifier { releve.posteID = classement.posteID; releve.aVerifier = classement.aVerifier }
            releve.modifiedAt = .now
            try context.save()
            return .rapprochee(posteID: releve.posteID, aVerifier: releve.aVerifier)
        }

        let nom = Classement.normaliser(commercant)
        let jour = Calendar.francais.startOfDay(for: date)
        let dejaLa = depenses.contains { d in
            d.montantCentimes == centimes && Calendar.francais.startOfDay(for: d.date) == jour
                && memeCommercant(nom, Classement.normaliser(d.commercant.isEmpty ? d.note : d.commercant))
        }
        if dejaLa { return .doublon }

        let depense = Depense(montantCentimes: centimes, posteID: classement.posteID, date: date, source: source)
        depense.commercant = commercant.trimmingCharacters(in: .whitespaces)
        depense.carte = carte.trimmingCharacters(in: .whitespaces)
        depense.aVerifier = classement.aVerifier
        context.insert(depense)
        try context.save()
        PactoleNotifications.verifierPlafond(apres: depense, dans: context)
        return .ajoutee(posteID: classement.posteID, aVerifier: classement.aVerifier)
    }

    /// Même commerçant : même nom, ou même premier mot d'au moins 3 lettres (« Joueclub La Recre » et la note
    /// « Joueclub — cadeau filleul » d'une dépense reprise du Suivi hebdo). Le jour et le montant sont déjà égaux.
    static func memeCommercant(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b || b.hasPrefix(a) || a.hasPrefix(b) { return true }
        guard let premierA = a.split(separator: " ").first, let premierB = b.split(separator: " ").first else { return false }
        return premierA.count >= 3 && premierA == premierB
    }

    /// Confirme une dépense de la file « À vérifier » dans un poste, et retient ce commerçant pour la suite
    /// (sauf Leclerc, qui garde sa règle des 13 €, et Imprévu, jamais automatique).
    static func confirmer(_ depense: Depense, posteID: String, dans context: ModelContext) throws {
        depense.posteID = posteID
        depense.aVerifier = false
        depense.modifiedAt = .now
        let nom = Classement.normaliser(depense.commercant)
        if !nom.isEmpty, posteID != Poste.imprevu, !nom.split(separator: " ").contains("leclerc") {
            let regles = try context.fetch(FetchDescriptor<Regle>())
            if let regle = regles.first(where: { $0.motif == nom }) {
                if regle.posteID != posteID { regle.posteID = posteID; regle.modifiedAt = .now }
            } else {
                context.insert(Regle(motif: nom, posteID: posteID))
            }
        }
        try context.save()
    }

    struct BilanCSV: Equatable {
        var ajoutees = 0
        var doublons = 0
        var illisibles = 0
    }

    /// Lit transactions.csv (« date;commercant;montant;carte », date « AAAA-MM-JJ HH:MM ») et ajoute les paiements absents.
    /// `traitees` : lignes déjà lues lors des passages précédents, ignorées. Chaque ligne n'est traitée qu'une fois :
    /// une dépense supprimée dans l'app ne revient pas à la lecture suivante.
    static func lireCSV(_ texte: String, traitees: inout Set<String>, dans context: ModelContext) throws -> BilanCSV {
        var bilan = BilanCSV()
        for brute in texte.split(whereSeparator: \.isNewline).map(String.init) {
            let ligne = brute.trimmingCharacters(in: .whitespaces)
            guard !traitees.contains(ligne) else { continue }
            let champs = ligne.split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard champs.count >= 3, champs[0] != "date", !champs[0].isEmpty else { continue }
            guard let date = dateCSV(champs[0]), let centimes = Montant.centimes(depuis: champs[2]), !champs[1].isEmpty else {
                bilan.illisibles += 1
                continue
            }
            switch try ajouter(commercant: champs[1], centimes: centimes, carte: champs.count > 3 ? champs[3] : "",
                               date: date, dans: context) {
            case .ajoutee: bilan.ajoutees += 1
            case .doublon, .rapprochee: bilan.doublons += 1
            }
            traitees.insert(ligne)
        }
        return bilan
    }

    static func dateCSV(_ texte: String) -> Date? {
        let format = DateFormatter()
        format.locale = Locale(identifier: "fr_FR")
        format.timeZone = .current
        for modele in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            format.dateFormat = modele
            if let date = format.date(from: texte) { return date }
        }
        return nil
    }
}

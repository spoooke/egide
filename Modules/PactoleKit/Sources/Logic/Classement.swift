import Foundation

/// Classement automatique des paiements (règles de ROADMAP.md, modifiables dans Réglages › Classement) :
/// - Leclerc d'un multiple exact de 13 € → Tabac ; sinon Courses, à vérifier ;
/// - sinon, la règle la plus précise (motif le plus long) contenue dans le nom du commerçant ;
/// - aucune règle → Divers, à vérifier ;
/// - jamais Imprévu automatiquement ;
/// - un commerçant jamais vu (aucune dépense confirmée à son nom) est toujours à vérifier.
enum Classement {
    struct Resultat: Equatable {
        var posteID: String
        var aVerifier: Bool
    }

    /// « E.Leclerc » → « e leclerc », « Intermarché » → « intermarche ».
    static func normaliser(_ texte: String) -> String {
        let sansAccents = texte.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
        let lettres = sansAccents.map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(lettres).split(separator: " ").joined(separator: " ")
    }

    /// - Parameters:
    ///   - regles: (motif normalisé, poste) ;
    ///   - commercantsConnus: commerçants normalisés ayant déjà une dépense confirmée.
    static func classer(commercant: String, centimes: Int, regles: [(motif: String, posteID: String)],
                        commercantsConnus: Set<String>) -> Resultat {
        let nom = normaliser(commercant)
        if nom.split(separator: " ").contains("leclerc") {
            return centimes > 0 && centimes % 13_00 == 0
                ? Resultat(posteID: "tabac", aVerifier: false)
                : Resultat(posteID: "courses", aVerifier: true)
        }
        let regle = regles.filter { !$0.motif.isEmpty && contient(nom, $0.motif) }
            .max { $0.motif.count < $1.motif.count }
        guard let regle, regle.posteID != Poste.imprevu else {
            return Resultat(posteID: Poste.divers, aVerifier: true)
        }
        return Resultat(posteID: regle.posteID, aVerifier: !commercantsConnus.contains(nom))
    }

    /// Motif présent comme mot(s) entier(s) : « tabac » trouve « tabac st antoine », pas « tabacologue ».
    private static func contient(_ nom: String, _ motif: String) -> Bool {
        " \(nom) ".contains(" \(motif) ")
    }
}

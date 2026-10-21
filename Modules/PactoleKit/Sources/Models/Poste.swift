import Foundation
import SwiftData

/// Catégorie de dépense, avec son plafond mensuel (nil : pas de plafond).
@Model
final class Poste {
    /// Identifiant stable : fixe pour les postes de départ, pour qu'ils ne soient jamais en double entre appareils.
    var syncID: String = UUID().uuidString
    var nom: String = ""
    var symbole: String = "tag"
    var plafondMensuelCentimes: Int?
    /// Compté hors du plafond de la semaine (Imprévu).
    var horsPlafondHebdo: Bool = false
    var ordre: Int = 0
    var modifiedAt: Date = Date.now

    init(syncID: String, nom: String, symbole: String, plafondMensuelCentimes: Int?, horsPlafondHebdo: Bool = false, ordre: Int) {
        self.syncID = syncID
        self.nom = nom
        self.symbole = symbole
        self.plafondMensuelCentimes = plafondMensuelCentimes
        self.horsPlafondHebdo = horsPlafondHebdo
        self.ordre = ordre
    }

    var plafondMensuel: Decimal? { plafondMensuelCentimes.map { Decimal($0) / 100 } }

    static let divers = "divers"
    static let imprevu = "imprevu"
    /// Frais pro : seul poste dont les dépenses peuvent être marquées remboursées.
    static let pro = "pro"

    /// Postes repris du « Suivi hebdo » (ROADMAP.md).
    static func depart() -> [Poste] {
        [
            Poste(syncID: "courses", nom: "Courses", symbole: "cart", plafondMensuelCentimes: 320_00, ordre: 0),
            Poste(syncID: "tabac", nom: "Tabac", symbole: "smoke", plafondMensuelCentimes: 150_00, ordre: 1),
            Poste(syncID: "restos", nom: "Restos et livraison", symbole: "fork.knife", plafondMensuelCentimes: 80_00, ordre: 2),
            Poste(syncID: "jeux", nom: "Jeux", symbole: "gamecontroller", plafondMensuelCentimes: 40_00, ordre: 3),
            Poste(syncID: "transport", nom: "Transport", symbole: "car", plafondMensuelCentimes: 40_00, ordre: 4),
            Poste(syncID: divers, nom: "Divers", symbole: "bag", plafondMensuelCentimes: 80_00, ordre: 5),
            Poste(syncID: imprevu, nom: "Imprévu", symbole: "exclamationmark.triangle", plafondMensuelCentimes: nil,
                  horsPlafondHebdo: true, ordre: 6),
            // Dépenses professionnelles : hors du budget perso de la semaine, sans plafond.
            Poste(syncID: "pro", nom: "Frais pro", symbole: "briefcase", plafondMensuelCentimes: nil,
                  horsPlafondHebdo: true, ordre: 7),
        ]
    }
}

/// Règle de classement des paiements : un commerçant dont le nom contient `motif` va dans le poste.
@Model
final class Regle {
    var syncID: String = UUID().uuidString
    /// Texte cherché dans le nom du commerçant, normalisé (minuscules, sans accents ni ponctuation).
    var motif: String = ""
    var posteID: String = Poste.divers
    var modifiedAt: Date = Date.now

    init(syncID: String? = nil, motif: String, posteID: String) {
        let motif = Classement.normaliser(motif)
        self.syncID = syncID ?? "regle-\(motif)"
        self.motif = motif
        self.posteID = posteID
    }

    /// Règles de départ (enseignes courantes). Leclerc a sa propre règle (Classement.classer).
    static func depart() -> [Regle] {
        let enseignes: [(String, [String])] = [
            ("courses", ["spar", "carrefour", "lidl", "intermarche", "super u", "hyper u", "auchan", "casino", "monoprix",
                         "franprix", "aldi", "netto", "leader price", "geant", "picard", "biocoop", "boulangerie"]),
            ("tabac", ["tabac"]),
            ("restos", ["burger king", "mcdonald", "kfc", "uber eats", "deliveroo", "just eat", "sushi", "pizza", "kebab",
                        "restaurant", "takos"]),
            ("transport", ["paybyphone", "sncf", "ouigo", "parking", "indigo", "totalenergies", "esso", "station"]),
            ("jeux", ["steam", "playstation", "nintendo", "xbox", "micromania", "epic games"]),
            (Poste.divers, ["joueclub", "king jouet", "grande recre", "jouet", "toys"]),
        ]
        return enseignes.flatMap { poste, motifs in motifs.map { Regle(motif: $0, posteID: poste) } }
    }
}

enum PactoleSchema {
    static let models: [any PersistentModel.Type] = [Depense.self, Poste.self, Regle.self, MoneyTombstone.self, FraisFixe.self, Revenu.self, Virement.self,
                                                     OperationVue.self, ReleveAjoute.self]
}

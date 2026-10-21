import Foundation
import SwiftData

/// Reprise des données de l'artefact « Suivi hebdo » (document data/users/<id>/budget de sa base, exporté en JSON) :
/// { "hebdo": 135, "plafonds": { "courses": 320, … }, "depenses": [ { "t": id, "d": "2026-10-02", "m": 12.5, "c": "courses", "n": "…" } ] }
/// Les identifiants de postes sont ceux de Money. Chaque dépense garde l'identifiant « t » de l'artefact :
/// un nouvel import du même fichier (ou d'un export plus récent) n'ajoute que les nouvelles dépenses.
struct SuiviHebdo: Decodable {
    struct Ligne: Decodable {
        var t: Double
        var d: String
        var m: Double
        var c: String
        var n: String?
    }

    var hebdo: Double?
    var plafonds: [String: Double]?
    var depenses: [Ligne]

    struct Bilan: Equatable {
        var ajoutees = 0
        var dejaPresentes = 0
        var ignorees = 0
    }

    static func decode(_ data: Data) throws -> SuiviHebdo {
        try JSONDecoder().decode(SuiviHebdo.self, from: data)
    }

    /// Identifiant de synchro d'une dépense de l'artefact.
    static func syncID(_ ligne: Ligne) -> String { "suivi-\(Int64(ligne.t))" }

    /// Jour « AAAA-MM-JJ » à midi (heure locale) : la dépense tombe toujours dans la bonne semaine et le bon mois.
    static func date(_ jour: String, calendrier: Calendar = .francais) -> Date? {
        let parties = jour.split(separator: "-").compactMap { Int($0) }
        guard parties.count == 3 else { return nil }
        return calendrier.date(from: DateComponents(year: parties[0], month: parties[1], day: parties[2], hour: 12))
    }

    /// Note de l'artefact : la mention « · Apple Pay » ajoutée par la routine devient la source de la dépense.
    static func noteEtSource(_ note: String?) -> (String, SourceDepense) {
        let texte = (note ?? "").trimmingCharacters(in: .whitespaces)
        let suffixe = " · Apple Pay"
        if texte.hasSuffix(suffixe) { return (String(texte.dropLast(suffixe.count)), .applePay) }
        if texte == "Apple Pay" { return ("", .applePay) }
        return (texte, .manuel)
    }

    /// Ajoute les dépenses absentes et reprend les plafonds. Ne modifie ni ne supprime aucune dépense existante.
    @MainActor
    func importer(dans context: ModelContext) throws -> Bilan {
        var bilan = Bilan()
        let postes = try context.fetch(FetchDescriptor<Poste>())
        let postesConnus = Set(postes.map(\.syncID))
        let existantes = Set(try context.fetch(FetchDescriptor<Depense>()).map(\.syncID))

        for ligne in depenses {
            let id = Self.syncID(ligne)
            guard !existantes.contains(id) else { bilan.dejaPresentes += 1; continue }
            guard let date = Self.date(ligne.d), ligne.m > 0 else { bilan.ignorees += 1; continue }
            let (note, source) = Self.noteEtSource(ligne.n)
            let depense = Depense(montantCentimes: Int((ligne.m * 100).rounded()),
                                  posteID: postesConnus.contains(ligne.c) ? ligne.c : Poste.divers,
                                  date: date, note: note, source: source)
            depense.syncID = id
            context.insert(depense)
            bilan.ajoutees += 1
        }

        if let hebdo, hebdo > 0 { PactoleReglages.plafondHebdoCentimes = Int((hebdo * 100).rounded()) }
        for poste in postes {
            guard let plafond = plafonds?[poste.syncID] else { continue }
            let centimes = plafond > 0 ? Int((plafond * 100).rounded()) : nil
            if poste.plafondMensuelCentimes != centimes {
                poste.plafondMensuelCentimes = centimes
                poste.modifiedAt = .now
            }
        }
        try context.save()
        return bilan
    }
}

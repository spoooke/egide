import Foundation
import SwiftData

/// Fichier transactions.csv (iCloud Drive), écrit par l'automatisation Raccourcis à chaque paiement :
/// relu à l'ouverture de Money pour rattraper les paiements arrivés pendant que l'action Égide échouait.
@MainActor
enum FichierSecours {
    static var nom: String? {
        guard let url = try? resoudre() else { return nil }
        return url.lastPathComponent
    }

    static func choisir(_ url: URL) throws {
        let acces = url.startAccessingSecurityScopedResource()
        defer { if acces { url.stopAccessingSecurityScopedResource() } }
        let signet = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(signet, forKey: PactoleReglages.cleSignetCSV)
    }

    static func oublier() {
        UserDefaults.standard.removeObject(forKey: PactoleReglages.cleSignetCSV)
    }

    /// Lit le fichier choisi (téléchargé depuis iCloud si besoin) et ajoute les paiements absents.
    /// nil si aucun fichier n'est choisi.
    static func lire(dans context: ModelContext) throws -> Paiements.BilanCSV? {
        guard let url = try resoudre() else { return nil }
        let acces = url.startAccessingSecurityScopedResource()
        defer { if acces { url.stopAccessingSecurityScopedResource() } }
        var texte = ""
        var erreurLecture: Error?
        var erreurCoordination: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &erreurCoordination) { lu in
            do { texte = try String(contentsOf: lu, encoding: .utf8) } catch { erreurLecture = error }
        }
        if let erreur = erreurCoordination ?? erreurLecture { throw erreur }
        var traitees = Set(UserDefaults.standard.stringArray(forKey: cleLignesTraitees) ?? [])
        let bilan = try Paiements.lireCSV(texte, traitees: &traitees, dans: context)
        UserDefaults.standard.set(Array(traitees), forKey: cleLignesTraitees)
        return bilan
    }

    /// Lignes du fichier déjà lues (propres à cet appareil).
    private static let cleLignesTraitees = "money.lignesCSVTraitees"

    private static func resoudre() throws -> URL? {
        guard let signet = UserDefaults.standard.data(forKey: PactoleReglages.cleSignetCSV) else { return nil }
        var perime = false
        let url = try URL(resolvingBookmarkData: signet, options: [], relativeTo: nil, bookmarkDataIsStale: &perime)
        if perime, let nouveau = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(nouveau, forKey: PactoleReglages.cleSignetCSV)
        }
        return url
    }
}

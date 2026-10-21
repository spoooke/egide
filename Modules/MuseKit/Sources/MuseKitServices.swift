import Foundation
import SwiftData

// Services de Muse pour l'app : résumé de l'Accueil, sauvegarde globale.
extension MuseKit {
    /// « 12 idées à faire · 2 aujourd'hui ».
    @MainActor
    public static func summary() async -> String? {
        guard let ideas = try? AppDatabase.container.mainContext.fetch(FetchDescriptor<Idea>()) else { return nil }
        let todo = ideas.filter { !$0.isDone }.count
        let today = ReminderViews.today(ideas).count
        var text = todo == 0 ? "Aucune idée à faire" : todo == 1 ? "1 idée à faire" : "\(todo) idées à faire"
        if today > 0 { text += " · \(today) aujourd'hui" }
        return text
    }

    /// Même contenu que « Exporter mes idées » (sans les images).
    @MainActor
    public static func backup() throws -> Data? {
        try Backup.export(from: AppDatabase.container.mainContext).data
    }

    /// Ajoute les idées absentes, ne remplace que par plus récent.
    @MainActor
    public static func restore(_ data: Data) throws -> String {
        let count = try Backup.restore(data, into: AppDatabase.container.mainContext)
        return count == 0 ? "déjà à jour" : "\(count) idée(s) restaurée(s)"
    }
}

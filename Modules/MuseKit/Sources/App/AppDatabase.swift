import EgideUI
import SwiftData

/// Base de l'app, partagée entre l'interface et les actions Siri / Raccourcis
/// (qui peuvent s'exécuter sans que l'interface soit ouverte).
@MainActor
enum AppDatabase {
    static let container: ModelContainer = {
        do {
            // Base nommée « Muse » : chaque module d'Égide garde sa propre base.
            let schema = Schema(AppSchema.models)
            if EgideDemo.actif {
                let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
                for (rang, texte) in ["Relire le devis de la cuisine avant vendredi", "Idée d'app : suivi des arrosages du jardin",
                                      "Rappeler le garage pour la révision", "Tester SwiftData avec un modèle versionné",
                                      "Préparer la liste pour le marché de samedi"].enumerated() {
                    container.mainContext.insert(Idea(text: texte, sortIndex: Double(rang),
                                                      createdAt: .now.addingTimeInterval(-Double(rang * rang + 1) * 7_200)))
                }
                try? container.mainContext.save()
                return container
            }
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration("Muse", schema: schema))
            SyncService.shared.attach(container)
            return container
        } catch {
            fatalError("Base de données illisible : \(error)")
        }
    }()
}

import Foundation
import SwiftData

/// Trace d'une idée supprimée, pour transmettre la suppression aux autres appareils.
@Model
final class SyncTombstone {
    var syncID: String = ""
    var deletedAt: Date = Date.now

    init(syncID: String, deletedAt: Date = .now) {
        self.syncID = syncID
        self.deletedAt = deletedAt
    }
}

/// Tous les modèles de l'app, en un seul endroit.
enum AppSchema {
    static let models: [any PersistentModel.Type] = [Idea.self, IdeaImage.self, Project.self, RoadmapItem.self, SyncTombstone.self]
}

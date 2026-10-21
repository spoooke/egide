import Foundation
import SwiftData

/// Projet importé depuis un fichier roadmap Markdown (ex. ROADMAP.md).
@Model
final class Project {
    var name: String = ""
    var createdAt: Date = Date.now
    var lastSyncedAt: Date?
    /// Signet vers le fichier choisi dans Fichiers, pour pouvoir le relire sans le redemander.
    var sourceBookmark: Data?
    var sourceFileName: String?

    @Relationship(deleteRule: .cascade, inverse: \RoadmapItem.project)
    var items: [RoadmapItem]? = []

    init(name: String) {
        self.name = name
    }

    /// Cases dans l'ordre du fichier.
    var sortedItems: [RoadmapItem] {
        (items ?? []).sorted { ($0.sectionIndex, $0.index) < ($1.sectionIndex, $1.index) }
    }

    var doneCount: Int { (items ?? []).filter(\.isDone).count }
    var totalCount: Int { items?.count ?? 0 }
}

/// Case à cocher d'une roadmap.
@Model
final class RoadmapItem {
    var text: String = ""
    var section: String = ""
    var sectionIndex: Int = 0
    var index: Int = 0
    /// État `- [x]` lu dans le fichier.
    var isDoneInFile: Bool = false
    /// Case cochée ou décochée sur l'iPhone : prioritaire sur le fichier.
    /// `nil` = suit le fichier.
    var phoneOverride: Bool?
    var project: Project?

    init(text: String, section: String, sectionIndex: Int, index: Int, isDoneInFile: Bool) {
        self.text = text
        self.section = section
        self.sectionIndex = sectionIndex
        self.index = index
        self.isDoneInFile = isDoneInFile
    }

    var isDone: Bool { phoneOverride ?? isDoneInFile }

    func toggle() {
        let newValue = !isDone
        // Revenir à l'état du fichier efface la surcharge.
        phoneOverride = newValue == isDoneInFile ? nil : newValue
    }
}

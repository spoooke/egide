import Foundation
import SwiftData

/// Une idée notée par l'utilisateur.
/// Toutes les propriétés ont une valeur par défaut et aucune n'est unique,
/// pour rester compatible avec une future synchro CloudKit.
@Model
final class Idea {
    var text: String = ""
    var isDone: Bool = false
    var createdAt: Date = Date.now
    var completedAt: Date?
    /// Ordre d'affichage dans « À faire » (croissant, la plus récente en haut).
    var sortIndex: Double = 0

    /// Identifiant partagé entre appareils (synchro par fichiers). Attribué à la création,
    /// ou à la première synchro pour les idées créées avant.
    var syncID: String = ""
    /// Dernière modification synchronisée (texte, état, ordre). Les rappels restent propres à l'appareil.
    var modifiedAt: Date = Date.distantPast

    /// Rappel optionnel : `nil` = pas de rappel.
    var reminderDate: Date?
    var reminderKindRaw: String = ReminderKind.notification.rawValue
    /// Identifiant de la notification ou de l'alarme programmée côté système.
    var reminderID: UUID?

    /// Priorité : 0 aucune, 1 basse, 2 moyenne, 3 haute (voir `Priority`).
    var priority: Int = 0
    /// Tags, sans « # ».
    var tags: [String] = []

    /// Captures d'écran et photos jointes.
    @Relationship(deleteRule: .cascade, inverse: \IdeaImage.idea)
    var images: [IdeaImage]? = []

    var sortedImages: [IdeaImage] {
        (images ?? []).sorted { $0.order < $1.order }
    }

    var reminderKind: ReminderKind {
        get { ReminderKind(rawValue: reminderKindRaw) ?? .notification }
        set { reminderKindRaw = newValue.rawValue }
    }

    /// Rappel programmé et pas encore passé.
    var hasUpcomingReminder: Bool {
        guard let reminderDate else { return false }
        return reminderDate > .now
    }

    init(text: String, sortIndex: Double = 0, createdAt: Date = .now) {
        self.text = text
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.syncID = UUID().uuidString
        self.modifiedAt = createdAt
    }

    /// À appeler après chaque modification à transmettre aux autres appareils.
    func touch(at date: Date = .now) {
        modifiedAt = date
        if syncID.isEmpty { syncID = UUID().uuidString }
    }
}

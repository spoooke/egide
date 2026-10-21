import Foundation
import SwiftData

/// Contenu du fichier `idees-<appareil>.json` écrit par chaque appareil dans le dossier de synchro.
struct SyncFile: Codable, Equatable, Sendable {
    struct IdeaRecord: Codable, Equatable, Sendable {
        var syncID: String
        var text: String
        var isDone: Bool
        var createdAt: Date
        var completedAt: Date?
        var sortIndex: Double
        var modifiedAt: Date
        /// Images jointes, dans l'ordre. `nil` dans les fichiers écrits avant l'ajout des images.
        var imageIDs: [String]? = nil
        /// `nil` dans les fichiers écrits avant l'ajout des priorités et des tags.
        var priority: Int? = nil
        var tags: [String]? = nil
    }

    struct TombstoneRecord: Codable, Equatable, Sendable {
        var syncID: String
        var deletedAt: Date
    }

    var version = 1
    var deviceID: String
    var deviceName: String
    var writtenAt: Date
    var ideas: [IdeaRecord]
    var tombstones: [TombstoneRecord]

    // Dates en secondes décimales (pas ISO 8601) pour garder la précision des comparaisons.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> SyncFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(SyncFile.self, from: data)
    }
}

/// Fusion des idées entre appareils : la modification la plus récente gagne,
/// une suppression gagne sur une modification plus ancienne.
@MainActor
enum IdeaSync {
    /// Durée de conservation des traces de suppression.
    static let tombstoneLifetime: TimeInterval = 30 * 24 * 3600

    /// État local à écrire dans le fichier de cet appareil.
    static func snapshot(of context: ModelContext, deviceID: String, deviceName: String, now: Date = .now) throws -> SyncFile {
        let ideas = try context.fetch(FetchDescriptor<Idea>())
        for idea in ideas where idea.syncID.isEmpty {
            idea.syncID = UUID().uuidString
        }

        let tombstones = try context.fetch(FetchDescriptor<SyncTombstone>())
        for tombstone in tombstones where now.timeIntervalSince(tombstone.deletedAt) > tombstoneLifetime {
            context.delete(tombstone)
        }

        return SyncFile(
            deviceID: deviceID,
            deviceName: deviceName,
            writtenAt: now,
            ideas: ideas.map {
                .init(syncID: $0.syncID, text: $0.text, isDone: $0.isDone, createdAt: $0.createdAt,
                      completedAt: $0.completedAt, sortIndex: $0.sortIndex, modifiedAt: $0.modifiedAt,
                      imageIDs: $0.sortedImages.map(\.imageID), priority: $0.priority, tags: $0.tags)
            },
            tombstones: tombstones
                .filter { now.timeIntervalSince($0.deletedAt) <= tombstoneLifetime }
                .map { .init(syncID: $0.syncID, deletedAt: $0.deletedAt) }
        )
    }

    /// Applique les fichiers des autres appareils. Retourne le nombre d'idées ajoutées, modifiées ou supprimées.
    @discardableResult
    static func merge(_ files: [SyncFile], into context: ModelContext) throws -> Int {
        var local = Dictionary(
            try context.fetch(FetchDescriptor<Idea>()).filter { !$0.syncID.isEmpty }.map { ($0.syncID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var deletions = Dictionary(
            try context.fetch(FetchDescriptor<SyncTombstone>()).map { ($0.syncID, $0) },
            uniquingKeysWith: { first, second in first.deletedAt >= second.deletedAt ? first : second }
        )
        var changes = 0

        // 1. Suppressions venues d'ailleurs.
        for record in files.flatMap(\.tombstones) {
            if let existing = deletions[record.syncID] {
                if record.deletedAt > existing.deletedAt { existing.deletedAt = record.deletedAt }
            } else {
                let tombstone = SyncTombstone(syncID: record.syncID, deletedAt: record.deletedAt)
                context.insert(tombstone)
                deletions[record.syncID] = tombstone
            }
            // Une modification locale postérieure à la suppression gagne.
            if let idea = local[record.syncID], idea.modifiedAt <= record.deletedAt {
                IdeaActions.clearReminder(for: idea)
                context.delete(idea)
                local[record.syncID] = nil
                changes += 1
            }
        }

        // 2. Ajouts et modifications : on garde la version la plus récente de chaque idée.
        let newest = Dictionary(files.flatMap(\.ideas).map { ($0.syncID, $0) }) {
            $0.modifiedAt >= $1.modifiedAt ? $0 : $1
        }
        for record in newest.values {
            if let tombstone = deletions[record.syncID], tombstone.deletedAt >= record.modifiedAt { continue }

            if let idea = local[record.syncID] {
                guard record.modifiedAt > idea.modifiedAt else { continue }
                apply(record, to: idea, context: context)
            } else {
                let idea = Idea(text: record.text)
                context.insert(idea)
                apply(record, to: idea, context: context)
                local[record.syncID] = idea
            }
            changes += 1
        }
        return changes
    }

    private static func apply(_ record: SyncFile.IdeaRecord, to idea: Idea, context: ModelContext) {
        if idea.isDone != record.isDone, record.isDone {
            // Terminée ailleurs : le rappel de cet appareil n'a plus lieu d'être.
            IdeaActions.clearReminder(for: idea)
        }
        idea.syncID = record.syncID
        idea.text = record.text
        idea.isDone = record.isDone
        idea.createdAt = record.createdAt
        idea.completedAt = record.completedAt
        idea.sortIndex = record.sortIndex
        idea.modifiedAt = record.modifiedAt
        if let priority = record.priority { idea.priority = priority }
        if let tags = record.tags { idea.tags = tags }
        if let imageIDs = record.imageIDs {
            applyImages(imageIDs, to: idea, context: context)
        }
    }

    /// Aligne les images de l'idée sur la liste reçue. Les nouvelles arrivent vides :
    /// leur contenu est téléchargé ensuite depuis le dossier `images/`.
    private static func applyImages(_ imageIDs: [String], to idea: Idea, context: ModelContext) {
        var existing = Dictionary((idea.images ?? []).map { ($0.imageID, $0) }, uniquingKeysWith: { first, _ in first })
        var kept: [IdeaImage] = []
        for (order, imageID) in imageIDs.enumerated() {
            let image = existing.removeValue(forKey: imageID) ?? {
                let placeholder = IdeaImage(imageID: imageID, order: order, data: nil)
                placeholder.isUploaded = true // elle vient du dossier, inutile de la renvoyer
                context.insert(placeholder)
                return placeholder
            }()
            image.order = order
            image.idea = idea
            kept.append(image)
        }
        for removed in existing.values { context.delete(removed) }
        idea.images = kept
    }
}

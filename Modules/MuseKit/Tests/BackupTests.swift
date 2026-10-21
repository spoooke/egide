import Foundation
import SwiftData
import Testing
@testable import MuseKit

struct ImageCleanupTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func removesOnlyOldUnreferencedImages() {
        let old = now.addingTimeInterval(-ImageCleanup.gracePeriod - 60)
        let recent = now.addingTimeInterval(-60)
        let files: [(name: String, modified: Date)] = [
            ("utilisee.jpg", old),
            ("orpheline.jpg", old),
            ("toute-neuve.jpg", recent),
            (".DS_Store", old),
        ]
        #expect(ImageCleanup.orphans(files: files, referenced: ["utilisee"], now: now) == ["orpheline.jpg"])
    }
}

@MainActor
@Suite(.serialized)
struct BackupTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(for: Schema(AppSchema.models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        IdeaActions.scheduler = SpyScheduler()
    }

    @Test func exportThenRestoreIntoEmptyBase() throws {
        IdeaActions.add("#pro !!! préparer la réunion", in: context)
        let deleted = try #require(IdeaActions.add("supprimée", in: context))
        IdeaActions.delete(deleted, in: context)
        let document = try Backup.export(from: context)

        let other = try ModelContainer(for: Schema(AppSchema.models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        #expect(try Backup.restore(document.data, into: other.mainContext) == 1)
        let restored = try #require(try other.mainContext.fetch(FetchDescriptor<Idea>()).first)
        #expect(restored.text == "préparer la réunion")
        #expect(restored.tags == ["pro"])
        #expect(restored.priorityLevel == .high)
    }

    @Test func restoreNeverDeletesAndKeepsNewerLocalVersion() throws {
        let idea = try #require(IdeaActions.add("version de la sauvegarde", in: context))
        let document = try Backup.export(from: context)
        idea.text = "version plus récente"
        idea.touch(at: idea.modifiedAt.addingTimeInterval(60))
        let other = try #require(IdeaActions.add("ajoutée après", in: context))

        #expect(try Backup.restore(document.data, into: context) == 0)
        #expect(idea.text == "version plus récente")
        #expect(try context.fetch(FetchDescriptor<Idea>()).contains { $0.persistentModelID == other.persistentModelID })
    }

    @Test func invalidFileIsRejected() {
        #expect(throws: (any Error).self) { try Backup.restore(Data("pas du json".utf8), into: context) }
    }

    @Test func fileNameContainsDate() {
        #expect(Backup.defaultFileName(now: Date(timeIntervalSince1970: 1_791_100_000)).hasPrefix("Muse-sauvegarde-2026-"))
    }
}

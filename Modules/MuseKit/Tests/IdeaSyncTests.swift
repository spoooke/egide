import Foundation
import SwiftData
import Testing
@testable import MuseKit

@MainActor
@Suite(.serialized)
struct IdeaSyncTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let t0 = Date(timeIntervalSince1970: 1_700_000_000) // 2023, avant « maintenant »

    init() throws {
        container = try ModelContainer(
            for: Schema(AppSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        IdeaActions.scheduler = SpyScheduler()
    }

    private func record(_ id: String, _ text: String, at date: Date, done: Bool = false) -> SyncFile.IdeaRecord {
        .init(syncID: id, text: text, isDone: done, createdAt: date, completedAt: done ? date : nil,
              sortIndex: 0, modifiedAt: date)
    }

    private func file(ideas: [SyncFile.IdeaRecord] = [], tombstones: [SyncFile.TombstoneRecord] = []) -> SyncFile {
        SyncFile(deviceID: "mac1", deviceName: "Mac", writtenAt: t0, ideas: ideas, tombstones: tombstones)
    }

    private func ideas() throws -> [Idea] {
        try context.fetch(FetchDescriptor<Idea>(sortBy: [SortDescriptor(\.text)]))
    }

    @Test func newIdeaHasSyncIdentity() throws {
        let idea = try #require(IdeaActions.add("Idée", in: context))
        #expect(!idea.syncID.isEmpty)
        #expect(idea.modifiedAt > .distantPast)
    }

    @Test func remoteIdeaIsAdded() throws {
        let changes = try IdeaSync.merge([file(ideas: [record("a", "Du Mac", at: t0)])], into: context)
        #expect(changes == 1)
        #expect(try ideas().map(\.text) == ["Du Mac"])
        #expect(try ideas().first?.syncID == "a")
    }

    @Test func newerRemoteVersionWins() throws {
        try IdeaSync.merge([file(ideas: [record("a", "Avant", at: t0)])], into: context)
        try IdeaSync.merge([file(ideas: [record("a", "Après", at: t0 + 60, done: true)])], into: context)
        let idea = try #require(try ideas().first)
        #expect(idea.text == "Après")
        #expect(idea.isDone)
    }

    @Test func olderRemoteVersionIsIgnored() throws {
        try IdeaSync.merge([file(ideas: [record("a", "Version locale", at: t0 + 60)])], into: context)
        let changes = try IdeaSync.merge([file(ideas: [record("a", "Vieille version", at: t0)])], into: context)
        #expect(changes == 0)
        #expect(try ideas().first?.text == "Version locale")
    }

    @Test func remoteDeletionRemovesIdea() throws {
        try IdeaSync.merge([file(ideas: [record("a", "À supprimer", at: t0)])], into: context)
        try IdeaSync.merge([file(tombstones: [.init(syncID: "a", deletedAt: t0 + 60)])], into: context)
        #expect(try ideas().isEmpty)
    }

    @Test func localEditAfterRemoteDeletionSurvives() throws {
        try IdeaSync.merge([file(ideas: [record("a", "Idée", at: t0)])], into: context)
        try #require(try ideas().first).touch(at: t0 + 120)
        try IdeaSync.merge([file(tombstones: [.init(syncID: "a", deletedAt: t0 + 60)])], into: context)
        #expect(try ideas().count == 1)
    }

    @Test func locallyDeletedIdeaIsNotResurrected() throws {
        try IdeaSync.merge([file(ideas: [record("a", "Idée", at: t0)])], into: context)
        IdeaActions.delete(try #require(try ideas().first), in: context)
        // L'autre appareil n'a pas encore vu la suppression et renvoie l'ancienne version.
        try IdeaSync.merge([file(ideas: [record("a", "Idée", at: t0)])], into: context)
        #expect(try ideas().isEmpty)
    }

    @Test func snapshotContainsIdeasAndDeletions() throws {
        IdeaActions.add("Gardée", in: context)
        let gone = try #require(IdeaActions.add("Supprimée", in: context))
        let goneID = gone.syncID
        IdeaActions.delete(gone, in: context)

        let snapshot = try IdeaSync.snapshot(of: context, deviceID: "ip1", deviceName: "iPhone")
        #expect(snapshot.ideas.map(\.text) == ["Gardée"])
        #expect(snapshot.tombstones.map(\.syncID) == [goneID])
    }

    @Test func snapshotGivesIdentityToOldIdeas() throws {
        let old = Idea(text: "Créée avant la synchro")
        old.syncID = ""
        context.insert(old)
        let snapshot = try IdeaSync.snapshot(of: context, deviceID: "ip1", deviceName: "iPhone")
        #expect(snapshot.ideas.first?.syncID.isEmpty == false)
    }

    @Test func oldTombstonesArePurged() throws {
        context.insert(SyncTombstone(syncID: "vieux", deletedAt: t0))
        let snapshot = try IdeaSync.snapshot(of: context, deviceID: "ip1", deviceName: "iPhone",
                                             now: t0 + IdeaSync.tombstoneLifetime + 1)
        #expect(snapshot.tombstones.isEmpty)
    }

    @Test func fileRoundTripKeepsSubSecondDates() throws {
        let original = file(ideas: [record("a", "Précise", at: t0 + 0.25)])
        #expect(try SyncFile.decode(original.encoded()) == original)
    }

    @Test func twoDevicesConverge() throws {
        // Appareil B dans une autre base.
        let other = try ModelContainer(for: Schema(AppSchema.models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        IdeaActions.add("Notée sur l'iPhone", in: context)
        IdeaActions.add("Notée sur le Mac", in: other.mainContext)

        let fromA = try IdeaSync.snapshot(of: context, deviceID: "a", deviceName: "iPhone")
        let fromB = try IdeaSync.snapshot(of: other.mainContext, deviceID: "b", deviceName: "Mac")
        try IdeaSync.merge([fromB], into: context)
        try IdeaSync.merge([fromA], into: other.mainContext)

        let textsA = try ideas().map(\.text)
        let textsB = try other.mainContext.fetch(FetchDescriptor<Idea>(sortBy: [SortDescriptor(\.text)])).map(\.text)
        #expect(textsA == ["Notée sur l'iPhone", "Notée sur le Mac"])
        #expect(textsA == textsB)
    }
}

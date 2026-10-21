import Foundation
import SwiftData
import Testing
@testable import MuseKit

struct CaptureParserTests {
    @Test func extractsTagsAndPriority() {
        let result = CaptureParser.parse("#tdl !!! corriger la synchro #Pro")
        #expect(result == .init(text: "corriger la synchro", tags: ["tdl", "Pro"], priority: .high))
    }

    @Test func doubleExclamationIsMedium() {
        #expect(CaptureParser.parse("appeler Paul !!").priority == .medium)
    }

    @Test func singleExclamationStaysText() {
        let result = CaptureParser.parse("Super idée !")
        #expect(result.text == "Super idée !")
        #expect(result.priority == .none)
    }

    @Test func highestPriorityWins() {
        #expect(CaptureParser.parse("!!! a !!").priority == .high)
    }

    @Test func duplicateTagsIgnoringCase() {
        #expect(CaptureParser.parse("#TDL x #tdl").tags == ["TDL"])
    }

    @Test func hashInsideWordIsText() {
        #expect(CaptureParser.parse("C# est un langage").text == "C# est un langage")
    }

    @Test func emptyHashIsIgnored() {
        #expect(CaptureParser.parse("# titre").tags.isEmpty)
    }
}

@MainActor
@Suite(.serialized)
struct OrganizationTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(for: Schema(AppSchema.models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        IdeaActions.scheduler = SpyScheduler()
    }

    @Test func quickCaptureSetsTagsAndPriority() throws {
        let idea = try #require(IdeaActions.add("#tdl !! mode sombre", in: context))
        #expect(idea.text == "mode sombre")
        #expect(idea.tags == ["tdl"])
        #expect(idea.priorityLevel == .medium)
    }

    @Test func captureWithOnlyTagsIsRejected() {
        #expect(IdeaActions.add("#tdl !!!", in: context) == nil)
    }

    @Test func todoOrderPutsPriorityFirstThenManualOrder() throws {
        let a = try #require(IdeaActions.add("a", in: context))
        let b = try #require(IdeaActions.add("b !!!", in: context))
        let c = try #require(IdeaActions.add("c", in: context))
        let sorted = [a, b, c].sorted(by: Idea.todoOrder).map(\.text)
        #expect(sorted == ["b", "c", "a"]) // b prioritaire, puis la plus récente en haut
    }

    @Test func tagEditingIgnoresDuplicatesAndTouches() throws {
        let idea = try #require(IdeaActions.add("Idée", in: context))
        idea.touch(at: .distantPast)
        IdeaActions.addTag("#Pro", to: idea)
        IdeaActions.addTag("pro", to: idea)
        #expect(idea.tags == ["Pro"])
        #expect(idea.modifiedAt > .distantPast)
        IdeaActions.removeTag("PRO", from: idea)
        #expect(idea.tags.isEmpty)
    }

    @Test func allTagsAreUniqueAndSorted() throws {
        IdeaActions.add("x #zeta #Alpha", in: context)
        IdeaActions.add("y #alpha #beta", in: context)
        // Ordre fixe : la première écriture d'un tag (« Alpha ») est gardée ; sans tri, l'ordre de SwiftData varie.
        let ideas = try context.fetch(FetchDescriptor<Idea>(sortBy: [SortDescriptor(\.createdAt)]))
        #expect(Tags.all(in: ideas) == ["Alpha", "beta", "zeta"])
    }

    @Test func tagColorIsStable() {
        #expect(Tags.color(for: "TDL") == Tags.color(for: "tdl"))
    }

    @Test func priorityAndTagsSync() throws {
        let idea = try #require(IdeaActions.add("#tdl !!! sync", in: context))
        let snapshot = try IdeaSync.snapshot(of: context, deviceID: "a", deviceName: "iPhone")
        #expect(snapshot.ideas.first?.priority == 3)
        #expect(snapshot.ideas.first?.tags == ["tdl"])

        var record = try #require(snapshot.ideas.first)
        record.priority = 1
        record.tags = ["pro"]
        record.modifiedAt = idea.modifiedAt.addingTimeInterval(60)
        let remote = SyncFile(deviceID: "b", deviceName: "Mac", writtenAt: .now, ideas: [record], tombstones: [])
        try IdeaSync.merge([remote], into: context)
        #expect(idea.priorityLevel == .low)
        #expect(idea.tags == ["pro"])
    }
}

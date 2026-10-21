import Foundation
import SwiftData
import Testing
@testable import MuseKit

struct RoadmapParserTests {
    let sample = """
    # ToDoList — Roadmap

    Intro sans case.

    ## Phase 0 — Mise en place ✅
    - [x] Projet Xcode
    - [X] Dépôt git

    ## Phase 1 — Capture
    - [ ] Champ de saisie **directement**
      - [ ] Sous-tâche indentée
    * [x] Liste

    ## Choix techniques
    | tableau | sans case |
    """

    @Test func readsTitleSectionsAndItems() {
        let roadmap = RoadmapParser.parse(sample)
        #expect(roadmap.title == "ToDoList — Roadmap")
        #expect(roadmap.sections.map(\.title) == ["Phase 0 — Mise en place", "Phase 1 — Capture"])
        #expect(roadmap.sections[0].items == [.init(text: "Projet Xcode", isDone: true), .init(text: "Dépôt git", isDone: true)])
        #expect(roadmap.sections[1].items.map(\.isDone) == [false, false, true])
        #expect(roadmap.itemCount == 5)
    }

    @Test func sectionWithoutItemsIsIgnored() {
        #expect(!RoadmapParser.parse(sample).sections.contains { $0.title == "Choix techniques" })
    }

    @Test func fileWithoutChecklistHasNoItems() {
        #expect(RoadmapParser.parse("# Titre\n\nDu texte.").itemCount == 0)
    }

    @Test func matchKeyIgnoresFormattingAndCase() {
        #expect(RoadmapParser.matchKey("Modèle `Idea`  **compatible**") == RoadmapParser.matchKey("modèle idea compatible"))
    }
}

@MainActor
struct RoadmapMergeTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(
            for: Schema(AppSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func makeProject(_ markdown: String) -> Project {
        let project = Project(name: "Test")
        context.insert(project)
        RoadmapSync.merge(RoadmapParser.parse(markdown), into: project, context: context)
        return project
    }

    private func item(_ project: Project, _ text: String) throws -> RoadmapItem {
        try #require(project.items?.first { $0.text == text })
    }

    @Test func importCreatesItemsInOrderWithFileState() throws {
        let project = makeProject("# Mon projet\n## A\n- [x] Un\n- [ ] Deux\n## B\n- [ ] Trois")
        #expect(project.name == "Mon projet")
        #expect(project.sortedItems.map(\.text) == ["Un", "Deux", "Trois"])
        #expect(project.sortedItems.map(\.isDone) == [true, false, false])
        #expect(project.doneCount == 1)
        #expect(project.lastSyncedAt != nil)
    }

    @Test func refreshKeepsItemsCheckedOnPhone() throws {
        let project = makeProject("## A\n- [ ] Un\n- [ ] Deux")
        try item(project, "Un").toggle()

        RoadmapSync.merge(RoadmapParser.parse("## A\n- [ ] Un\n- [ ] Deux\n- [ ] Nouveau"), into: project, context: context)

        #expect(try item(project, "Un").isDone)
        #expect(project.totalCount == 3)
    }

    @Test func refreshKeepsItemsUncheckedOnPhone() throws {
        let project = makeProject("## A\n- [x] Un")
        try item(project, "Un").toggle()
        RoadmapSync.merge(RoadmapParser.parse("## A\n- [x] Un"), into: project, context: context)
        #expect(try !item(project, "Un").isDone)
    }

    @Test func overrideClearsWhenFileCatchesUp() throws {
        let project = makeProject("## A\n- [ ] Un")
        try item(project, "Un").toggle()
        RoadmapSync.merge(RoadmapParser.parse("## A\n- [x] Un"), into: project, context: context)
        let un = try item(project, "Un")
        #expect(un.isDone)
        #expect(un.phoneOverride == nil)
    }

    @Test func togglingBackToFileStateClearsOverride() throws {
        let project = makeProject("## A\n- [ ] Un")
        let un = try item(project, "Un")
        un.toggle()
        un.toggle()
        #expect(un.phoneOverride == nil)
        #expect(!un.isDone)
    }

    @Test func itemsMovedOrReformattedKeepTheirCheck() throws {
        let project = makeProject("## Phase 1\n- [ ] Liste de courses")
        try item(project, "Liste de courses").toggle()
        RoadmapSync.merge(RoadmapParser.parse("## Phase 3 ✅\n- [ ] **Liste** de courses"), into: project, context: context)
        let moved = try item(project, "**Liste** de courses")
        #expect(moved.isDone)
        #expect(moved.section == "Phase 3")
    }

    @Test func itemsRemovedFromFileAreDeleted() throws {
        let project = makeProject("## A\n- [ ] Un\n- [ ] Deux")
        RoadmapSync.merge(RoadmapParser.parse("## A\n- [ ] Deux"), into: project, context: context)
        #expect(project.sortedItems.map(\.text) == ["Deux"])
        #expect(try context.fetchCount(FetchDescriptor<RoadmapItem>()) == 1)
    }

    @Test func duplicateItemsAreKeptSeparately() throws {
        let project = makeProject("## A\n- [ ] Tester\n## B\n- [ ] Tester")
        RoadmapSync.merge(RoadmapParser.parse("## A\n- [ ] Tester\n## B\n- [ ] Tester"), into: project, context: context)
        #expect(project.totalCount == 2)
    }
}

struct RoadmapRemovalTests {
    let markdown = """
    # Roadmap

    ## Phase 1 ✅
    - [x] Garder
    - [ ] **Supprimer** moi
    - [ ] Doublon

    ## Phase 2
    - [ ] Doublon
    - [ ] Autre
    """

    @Test func removesOnlyTheMatchingLine() throws {
        let updated = try #require(RoadmapParser.removingItem(text: "**Supprimer** moi", section: "Phase 1", from: markdown))
        #expect(!updated.contains("Supprimer"))
        #expect(updated.components(separatedBy: "\n").count == markdown.components(separatedBy: "\n").count - 1)
        #expect(RoadmapParser.parse(updated).itemCount == 4)
    }

    @Test func duplicateIsRemovedFromTheRightSection() throws {
        let updated = try #require(RoadmapParser.removingItem(text: "Doublon", section: "Phase 2", from: markdown))
        let sections = RoadmapParser.parse(updated).sections
        #expect(sections[0].items.map(\.text).contains("Doublon"))
        #expect(!sections[1].items.map(\.text).contains("Doublon"))
    }

    @Test func movedItemIsStillFound() throws {
        let updated = try #require(RoadmapParser.removingItem(text: "Autre", section: "Ancienne section", from: markdown))
        #expect(!updated.contains("Autre"))
    }

    @Test func missingItemReturnsNil() {
        #expect(RoadmapParser.removingItem(text: "Inexistant", section: "Phase 1", from: markdown) == nil)
    }

    @Test func restOfFileIsUntouched() throws {
        let updated = try #require(RoadmapParser.removingItem(text: "Garder", section: "Phase 1", from: markdown))
        #expect(updated.hasPrefix("# Roadmap\n\n## Phase 1 ✅\n- [ ] **Supprimer** moi"))
    }
}

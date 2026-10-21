import Foundation
import SwiftData
import Testing
@testable import MuseKit

@MainActor
final class SpyScheduler: ReminderScheduling {
    var scheduled: [UUID: (date: Date, kind: ReminderKind, text: String)] = [:]
    var cancelled: [UUID] = []
    var failure: Error?

    func schedule(id: UUID, text: String, date: Date, kind: ReminderKind) async throws {
        if let failure { throw failure }
        scheduled[id] = (date, kind, text)
    }

    func cancel(id: UUID) {
        cancelled.append(id)
        scheduled[id] = nil
    }
}

// `.serialized` : les tests partagent `IdeaActions.scheduler`.
@MainActor
@Suite(.serialized)
struct IdeaActionsTests {
    let container: ModelContainer
    let spy = SpyScheduler()
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(
            for: Schema(AppSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        IdeaActions.scheduler = spy
    }

    private func sortedIdeas() throws -> [Idea] {
        try context.fetch(FetchDescriptor<Idea>(sortBy: [SortDescriptor(\.sortIndex)]))
    }

    @Test func addTrimsText() throws {
        IdeaActions.add("  Acheter du pain \n", in: context)
        #expect(try sortedIdeas().map(\.text) == ["Acheter du pain"])
    }

    @Test func addIgnoresBlankText() throws {
        #expect(IdeaActions.add("   \n ", in: context) == nil)
        #expect(try sortedIdeas().isEmpty)
    }

    @Test func newestIdeaGoesOnTop() throws {
        IdeaActions.add("Première", in: context)
        IdeaActions.add("Deuxième", in: context)
        IdeaActions.add("Troisième", in: context)
        #expect(try sortedIdeas().map(\.text) == ["Troisième", "Deuxième", "Première"])
    }

    @Test func toggleSetsAndClearsCompletionDate() throws {
        let idea = try #require(IdeaActions.add("Idée", in: context))
        IdeaActions.toggle(idea)
        #expect(idea.isDone)
        #expect(idea.completedAt != nil)
        IdeaActions.toggle(idea)
        #expect(!idea.isDone)
        #expect(idea.completedAt == nil)
    }

    @Test func setDoneIsIdempotent() throws {
        let idea = try #require(IdeaActions.add("Idée", in: context))
        IdeaActions.setDone(true, for: idea)
        let firstCompletion = try #require(idea.completedAt)
        IdeaActions.setDone(true, for: idea)
        #expect(idea.completedAt == firstCompletion)
        IdeaActions.setDone(false, for: idea)
        #expect(!idea.isDone)
        #expect(idea.completedAt == nil)
    }

    @Test func deleteRemovesIdea() throws {
        let idea = try #require(IdeaActions.add("À supprimer", in: context))
        IdeaActions.delete(idea, in: context)
        #expect(try sortedIdeas().isEmpty)
    }

    @Test func moveReordersIdeas() throws {
        IdeaActions.add("C", in: context)
        IdeaActions.add("B", in: context)
        IdeaActions.add("A", in: context)
        // A, B, C → déplacer A en dernier
        IdeaActions.move(try sortedIdeas(), from: IndexSet(integer: 0), to: 3)
        #expect(try sortedIdeas().map(\.text) == ["B", "C", "A"])
        // Une nouvelle idée arrive toujours en haut après un réordonnancement.
        IdeaActions.add("Nouvelle", in: context)
        #expect(try sortedIdeas().first?.text == "Nouvelle")
    }

    // MARK: - Rappels

    @Test func newIdeaHasNoReminder() throws {
        let idea = try #require(IdeaActions.add("Idée", in: context))
        #expect(idea.reminderDate == nil)
        #expect(!idea.hasUpcomingReminder)
    }

    @Test func setReminderSchedulesIt() async throws {
        let idea = try #require(IdeaActions.add("Appeler Paul", in: context))
        let date = Date.now.addingTimeInterval(3600)
        try await IdeaActions.setReminder(date, kind: .alarm, for: idea)

        let id = try #require(idea.reminderID)
        #expect(idea.reminderDate == date)
        #expect(idea.reminderKind == .alarm)
        #expect(spy.scheduled[id]?.kind == .alarm)
        #expect(spy.scheduled[id]?.text == "Appeler Paul")
    }

    @Test func changingReminderKeepsSingleScheduledReminder() async throws {
        let idea = try #require(IdeaActions.add("Idée", in: context))
        try await IdeaActions.setReminder(.now.addingTimeInterval(3600), kind: .notification, for: idea)
        try await IdeaActions.setReminder(.now.addingTimeInterval(7200), kind: .alarm, for: idea)
        #expect(spy.scheduled.count == 1)
        #expect(spy.scheduled.values.first?.kind == .alarm)
    }

    @Test func reminderInThePastIsRejected() async throws {
        let idea = try #require(IdeaActions.add("Idée", in: context))
        await #expect(throws: ReminderError.dateInPast) {
            try await IdeaActions.setReminder(.now.addingTimeInterval(-60), kind: .notification, for: idea)
        }
        #expect(idea.reminderDate == nil)
        #expect(spy.scheduled.isEmpty)
    }

    @Test func failedSchedulingLeavesNoReminder() async throws {
        let idea = try #require(IdeaActions.add("Idée", in: context))
        spy.failure = ReminderError.notAuthorized(.alarm)
        await #expect(throws: ReminderError.notAuthorized(.alarm)) {
            try await IdeaActions.setReminder(.now.addingTimeInterval(3600), kind: .alarm, for: idea)
        }
        #expect(idea.reminderDate == nil)
    }

    @Test func markingDoneCancelsReminder() async throws {
        let idea = try #require(IdeaActions.add("Idée", in: context))
        try await IdeaActions.setReminder(.now.addingTimeInterval(3600), kind: .notification, for: idea)
        IdeaActions.setDone(true, for: idea)
        #expect(idea.reminderDate == nil)
        #expect(spy.scheduled.isEmpty)
    }

    @Test func deletingCancelsReminder() async throws {
        let idea = try #require(IdeaActions.add("Idée", in: context))
        try await IdeaActions.setReminder(.now.addingTimeInterval(3600), kind: .alarm, for: idea)
        IdeaActions.delete(idea, in: context)
        #expect(spy.scheduled.isEmpty)
    }

    @Test func defaultReminderIsNextFullHourAtLeast30MinutesAway() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Paris"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 9, minute: 40)))
        let expected = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 11, minute: 0)))
        #expect(IdeaActions.defaultReminderDate(from: now, calendar: calendar) == expected)
    }

    // MARK: - Raccourcis de rappel

    private func parisCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Paris"))
        return calendar
    }

    private func date(_ calendar: Calendar, day: Int, hour: Int, minute: Int, second: Int = 0) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second)))
    }

    @Test func presetInOneHourIsRoundedToTheMinute() throws {
        let calendar = try parisCalendar()
        let now = try date(calendar, day: 4, hour: 9, minute: 40, second: 37)
        #expect(ReminderPreset.inOneHour.date(from: now, calendar: calendar) == (try date(calendar, day: 4, hour: 10, minute: 40)))
    }

    @Test func presetTonightIsTodayAt20h() throws {
        let calendar = try parisCalendar()
        let now = try date(calendar, day: 4, hour: 9, minute: 40)
        #expect(ReminderPreset.tonight.date(from: now, calendar: calendar) == (try date(calendar, day: 4, hour: 20, minute: 0)))
    }

    @Test func presetTonightIsUnavailableAfter20h() throws {
        let calendar = try parisCalendar()
        let now = try date(calendar, day: 4, hour: 21, minute: 15)
        #expect(ReminderPreset.tonight.date(from: now, calendar: calendar) == nil)
    }

    @Test func presetTomorrowMorningIsTomorrowAt9h() throws {
        let calendar = try parisCalendar()
        let now = try date(calendar, day: 4, hour: 23, minute: 50)
        #expect(ReminderPreset.tomorrowMorning.date(from: now, calendar: calendar) == (try date(calendar, day: 5, hour: 9, minute: 0)))
    }
}

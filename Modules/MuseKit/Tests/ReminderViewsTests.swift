import Foundation
import SwiftData
import Testing
@testable import MuseKit

@MainActor
@Suite(.serialized)
struct ReminderViewsTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let calendar: Calendar
    let now: Date

    init() throws {
        container = try ModelContainer(for: Schema(AppSchema.models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Paris"))
        self.calendar = calendar
        now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 14, minute: 0)))
    }

    private func idea(_ text: String, reminderInHours hours: Double?, done: Bool = false) -> Idea {
        let idea = Idea(text: text)
        idea.reminderDate = hours.map { now.addingTimeInterval($0 * 3600) }
        idea.isDone = done
        context.insert(idea)
        return idea
    }

    @Test func todayIncludesLaterTodayAndOverdueSortedByTime() {
        let ideas = [
            idea("ce soir", reminderInHours: 6),        // 20 h
            idea("en retard", reminderInHours: -26),    // hier
            idea("demain", reminderInHours: 20),        // demain 10 h
            idea("sans rappel", reminderInHours: nil),
            idea("faite", reminderInHours: 1, done: true),
        ]
        #expect(ReminderViews.today(ideas, now: now, calendar: calendar).map(\.text) == ["en retard", "ce soir"])
    }

    @Test func upcomingGroupsByDayAfterToday() {
        let ideas = [
            idea("ce soir", reminderInHours: 6),
            idea("demain soir", reminderInHours: 30),
            idea("demain matin", reminderInHours: 20),
            idea("dans 3 jours", reminderInHours: 72),
        ]
        let groups = ReminderViews.upcoming(ideas, now: now, calendar: calendar)
        #expect(groups.map { $0.ideas.map(\.text) } == [["demain matin", "demain soir"], ["dans 3 jours"]])
        #expect(ReminderViews.dayTitle(groups[0].day, now: now, calendar: calendar) == "Demain")
    }

    @Test func overdueOnlyWhenNotDone() {
        #expect(ReminderViews.isOverdue(idea("x", reminderInHours: -1), now: now))
        #expect(!ReminderViews.isOverdue(idea("y", reminderInHours: -1, done: true), now: now))
        #expect(!ReminderViews.isOverdue(idea("z", reminderInHours: 1), now: now))
    }
}

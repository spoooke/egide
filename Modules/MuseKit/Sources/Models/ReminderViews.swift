import Foundation

/// Sélection des idées pour les vues « Aujourd'hui » et « À venir » (rappels de cet appareil).
enum ReminderViews {
    /// Idées à faire dont le rappel tombe aujourd'hui, ou est passé sans qu'elles soient faites.
    static func today(_ ideas: [Idea], now: Date = .now, calendar: Calendar = .current) -> [Idea] {
        let endOfToday = calendar.startOfDay(for: now).addingTimeInterval(24 * 3600)
        return withReminder(ideas).filter { $0.reminderDate! < endOfToday }
    }

    /// Idées à faire dont le rappel tombe après aujourd'hui, regroupées par jour.
    static func upcoming(_ ideas: [Idea], now: Date = .now, calendar: Calendar = .current) -> [(day: Date, ideas: [Idea])] {
        let endOfToday = calendar.startOfDay(for: now).addingTimeInterval(24 * 3600)
        let later = withReminder(ideas).filter { $0.reminderDate! >= endOfToday }
        let byDay = Dictionary(grouping: later) { calendar.startOfDay(for: $0.reminderDate!) }
        return byDay.keys.sorted().map { (day: $0, ideas: byDay[$0]!) }
    }

    /// Rappel passé alors que l'idée n'est pas faite.
    static func isOverdue(_ idea: Idea, now: Date = .now) -> Bool {
        guard !idea.isDone, let date = idea.reminderDate else { return false }
        return date < now
    }

    /// Titre de section : « Demain », sinon « mardi 6 oct. ».
    static func dayTitle(_ day: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now.addingTimeInterval(24 * 3600)) { return "Demain" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    private static func withReminder(_ ideas: [Idea]) -> [Idea] {
        ideas.filter { !$0.isDone && $0.reminderDate != nil }
            .sorted { $0.reminderDate! < $1.reminderDate! }
    }
}

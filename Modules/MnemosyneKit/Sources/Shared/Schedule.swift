import Foundation

/// How often to be reminded, always counted from the last successful backup.
public struct Schedule: Codable, Equatable, Sendable {
    public enum Frequency: String, Codable, CaseIterable, Sendable {
        case monthly, weekly
    }

    public var frequency: Frequency
    /// Day of the weekly reminder, as `Calendar` counts it: 1 = Sunday … 7 = Saturday.
    public var weekday: Int
    /// Hour of the day the reminder shows up.
    public var hour: Int

    public init(frequency: Frequency = .monthly, weekday: Int = 1, hour: Int = 10) {
        self.frequency = frequency
        self.weekday = weekday
        self.hour = hour
    }

    /// When the next backup is due. Monthly: same day next month. Weekly: the chosen weekday,
    /// skipped when it falls less than 4 days after the backup (a Saturday backup is not due on Sunday).
    /// Never backed up: due right away.
    public func due(after lastBackup: Date?, now: Date = .now, calendar: Calendar = .current) -> Date {
        guard let lastBackup else { return now }
        let day = calendar.startOfDay(for: lastBackup)
        let dueDay: Date
        switch frequency {
        case .monthly:
            dueDay = calendar.date(byAdding: .month, value: 1, to: day)!
        case .weekly:
            let earliest = calendar.date(byAdding: .day, value: 4, to: day)!
            dueDay = calendar.nextDate(after: calendar.date(byAdding: .second, value: -1, to: earliest)!,
                                       matching: DateComponents(weekday: weekday), matchingPolicy: .nextTime)!
        }
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: dueDay)!
    }

    /// Reminders still to come: the due date, then two nudges if no backup happens (2 and 7 days later).
    public func reminders(after lastBackup: Date?, now: Date = .now, calendar: Calendar = .current) -> [Date] {
        let due = due(after: lastBackup, now: now, calendar: calendar)
        return [0, 2, 7].map { calendar.date(byAdding: .day, value: $0, to: due)! }.filter { $0 > now }
    }

    public var text: String {
        switch frequency {
        case .monthly: "Une fois par mois"
        case .weekly: "Chaque semaine, le \(Self.weekdayName(weekday))"
        }
    }

    public static func weekdayName(_ weekday: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "fr_FR")
        return calendar.weekdaySymbols[(weekday - 1) % 7]
    }
}

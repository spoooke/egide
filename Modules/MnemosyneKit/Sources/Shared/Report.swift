import Foundation

/// What the Mac sends to the Argos server once a minute (POST /api/mnemosyne), and what the iPhone reads back
/// (GET /api/mnemosyne, with the time it was received). Same keys as the server (Argos/argos/cmd/server/mnemosyne.go).
public struct Report: Codable, Equatable, Sendable {
    public struct Disk: Codable, Equatable, Sendable {
        /// Time Machine destination ID (`tmutil destinationinfo`).
        public var id: String
        public var name: String
        public var mounted: Bool
        public var quotaGB: Int?

        public init(id: String, name: String, mounted: Bool, quotaGB: Int? = nil) {
            self.id = id
            self.name = name
            self.mounted = mounted
            self.quotaGB = quotaGB
        }
    }

    public struct Progress: Codable, Equatable, Sendable {
        /// `BackupPhase` from `tmutil status`: Starting, Copying, Finishing…
        public var phase: String
        /// 0 to 1, -1 while Time Machine does not know yet.
        public var percent: Double

        public init(phase: String, percent: Double) {
            self.phase = phase
            self.percent = percent
        }

        public var text: String {
            let step = switch phase {
            case "Starting", "MountingBackupVol", "PreparingSourceVolumes", "FindingChanges", "ThinningPreBackup": "Préparation"
            case "Copying": "Copie"
            case "ThinningPostBackup", "Finishing": "Fin"
            default: "En cours"
            }
            return percent >= 0 ? "\(step) · \(percent.formatted(.percent.precision(.fractionLength(0))))" : step
        }
    }

    public struct Failure: Codable, Equatable, Sendable {
        public var at: Date
        public var reason: String

        public init(at: Date, reason: String) {
            self.at = at
            self.reason = reason
        }
    }

    /// One past backup, as the history lists it.
    public struct Entry: Codable, Equatable, Sendable {
        public var start: Date?
        public var end: Date
        /// nil when it succeeded.
        public var failure: String?
        /// Disk name at the time.
        public var disk: String?

        public init(start: Date?, end: Date, failure: String?, disk: String?) {
            self.start = start
            self.end = end
            self.failure = failure
            self.disk = disk
        }

        public var succeeded: Bool { failure == nil }

        /// « moins d'une minute », « 35 min », « 1 h 10 ».
        public var duration: String? {
            guard let start, end >= start else { return nil }
            let minutes = Int(end.timeIntervalSince(start) / 60)
            if minutes < 1 { return "moins d'une minute" }
            if minutes < 60 { return "\(minutes) min" }
            return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(String(format: "%02d", minutes % 60))"
        }
    }

    public var lastBackup: Date?
    public var disk: Disk?
    public var running: Progress?
    public var schedule: Schedule
    /// Last failed backup, when it is more recent than the last successful one.
    public var failure: Failure?
    /// Sent once per failure: the server forwards it to ntfy.
    public var alert: Bool?
    /// Last backups, most recent first.
    public var history: [Entry]?
    /// Filled by the server: when this report was received.
    public var at: Date?
    /// Filled by the server: the iPhone asked for a backup the Mac has not started yet.
    public var backupRequested: Bool?

    public init(lastBackup: Date?, disk: Disk?, running: Progress?, schedule: Schedule, failure: Failure?, alert: Bool? = nil,
                history: [Entry]? = nil) {
        self.history = history
        self.lastBackup = lastBackup
        self.disk = disk
        self.running = running
        self.schedule = schedule
        self.failure = failure
        self.alert = alert
    }

    public var due: Date { schedule.due(after: lastBackup) }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// How regular the backups are: for each successful one, the time since the previous success,
/// and how late it came compared with the reminder in force.
public struct Regularity: Equatable, Sendable {
    /// Days since the previous successful backup (nil for the oldest one listed).
    public var daysSincePrevious: Int?
    /// Days after the due date of the previous backup (0 when on time).
    public var daysLate: Int

    public static func of(_ history: [Report.Entry], schedule: Schedule, calendar: Calendar = .current) -> [Date: Regularity] {
        let successes = history.filter(\.succeeded).map(\.end).sorted()
        var result: [Date: Regularity] = [:]
        for (index, end) in successes.enumerated() {
            guard index > 0 else {
                result[end] = Regularity(daysSincePrevious: nil, daysLate: 0)
                continue
            }
            let previous = successes[index - 1]
            let due = schedule.due(after: previous, calendar: calendar)
            let since = calendar.dateComponents([.day], from: calendar.startOfDay(for: previous), to: calendar.startOfDay(for: end)).day ?? 0
            let late = end > due ? (calendar.dateComponents([.day], from: calendar.startOfDay(for: due), to: calendar.startOfDay(for: end)).day ?? 0) : 0
            result[end] = Regularity(daysSincePrevious: since, daysLate: late)
        }
        return result
    }

    /// « le même jour », « 12 jours après la précédente », « … , 3 jours de retard ».
    public var text: String? {
        guard let days = daysSincePrevious else { return nil }
        let since = days == 0 ? "le même jour que la précédente" : "\(days) jour\(days > 1 ? "s" : "") après la précédente"
        return daysLate > 0 ? "\(since), \(daysLate) jour\(daysLate > 1 ? "s" : "") de retard" : since
    }
}

public enum Wording {
    /// « il y a 3 jours », « aujourd'hui à 11:40 ».
    public static func since(_ date: Date, now: Date = .now) -> String {
        if Calendar.current.isDateInToday(date) { return "aujourd'hui à \(date.formatted(date: .omitted, time: .shortened))" }
        if Calendar.current.isDateInYesterday(date) { return "hier à \(date.formatted(date: .omitted, time: .shortened))" }
        return date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    /// « sam. 24 oct. à 12:33 ».
    public static func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    /// « le 24 novembre à 10:00 », or « en retard depuis 3 jours ».
    public static func due(_ date: Date, now: Date = .now) -> String {
        if date <= now {
            let days = Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0
            return days < 1 ? "maintenant" : "en retard de \(days) jour\(days > 1 ? "s" : "")"
        }
        return "le \(dayAndMonth(date)) à \(date.formatted(date: .omitted, time: .shortened))"
    }

    /// « 24 novembre », « 1er novembre ».
    public static func dayAndMonth(_ date: Date) -> String {
        let day = Calendar.current.component(.day, from: date)
        return "\(day == 1 ? "1er" : String(day)) \(date.formatted(.dateTime.month(.wide)))"
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

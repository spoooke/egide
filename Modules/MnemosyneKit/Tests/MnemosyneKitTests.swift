import Foundation
import Testing
@testable import MnemosyneKit

struct MnemosyneKitTests {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    func date(_ day: Int, _ month: Int = 10, hour: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    @Test func monthlyCountsFromLastBackup() {
        let schedule = Schedule()
        #expect(schedule.due(after: date(24), calendar: calendar) == date(24, 11, hour: 10))
        // 31 January → end of February, not March.
        let january = calendar.date(from: DateComponents(year: 2027, month: 1, day: 31, hour: 9))!
        #expect(calendar.component(.month, from: schedule.due(after: january, calendar: calendar)) == 2)
    }

    @Test func weeklySkipsADayTooClose() {
        // 24 October 2026 is a Saturday. Sunday chosen: the 25th is too close, the 1st of November is due.
        let sunday = Schedule(frequency: .weekly, weekday: 1, hour: 9)
        #expect(sunday.due(after: date(24), calendar: calendar) == date(1, 11, hour: 9))
        // Wednesday chosen: the 28th is 4 days later, kept.
        let wednesday = Schedule(frequency: .weekly, weekday: 4, hour: 9)
        #expect(wednesday.due(after: date(24), calendar: calendar) == date(28, hour: 9))
        // Same weekday as the backup: a week later.
        let saturday = Schedule(frequency: .weekly, weekday: 7, hour: 9)
        #expect(saturday.due(after: date(24), calendar: calendar) == date(31, hour: 9))
    }

    @Test func neverBackedUpIsDueNow() {
        let now = date(24)
        #expect(Schedule().due(after: nil, now: now, calendar: calendar) == now)
    }

    @Test func remindersAfterDueDate() {
        let schedule = Schedule(frequency: .weekly, weekday: 4, hour: 9)
        let all = schedule.reminders(after: date(24), now: date(24), calendar: calendar)
        #expect(all == [date(28, hour: 9), date(30, hour: 9), date(4, 11, hour: 9)])
        // A recent backup leaves nothing overdue; two days past due, only the later nudges remain.
        #expect(schedule.reminders(after: date(24), now: date(29), calendar: calendar).count == 2)
    }

    @Test func regularityAndDuration() {
        let monthly = Schedule()
        let history = [
            Report.Entry(start: date(28, 11, hour: 10), end: date(28, 11, hour: 11), failure: nil, disk: "Time Machine"),
            Report.Entry(start: nil, end: date(27, 11, hour: 9), failure: "Plus assez de place sur le disque de sauvegarde.", disk: nil),
            Report.Entry(start: date(24, hour: 10), end: date(24, hour: 11).addingTimeInterval(-25 * 60), failure: nil, disk: "Time Machine"),
        ]
        let regularity = Regularity.of(history, schedule: monthly, calendar: calendar)
        // Due on 24 November at 10:00: done on the 28th, 4 days late; the failure counts for nothing.
        #expect(regularity[date(28, 11, hour: 11)] == Regularity(daysSincePrevious: 35, daysLate: 4))
        #expect(regularity[date(24, hour: 11).addingTimeInterval(-25 * 60)]?.daysSincePrevious == nil)
        #expect(regularity[date(27, 11, hour: 9)] == nil)
        #expect(history[0].duration == "1 h" && history[2].duration == "35 min" && history[1].duration == nil)
    }

    @Test func reportMatchesServerKeys() throws {
        let json = #"{"at":"2026-10-24T09:41:00Z","lastBackup":"2026-10-24T09:40:00Z","disk":{"id":"402F","name":"Time Machine","mounted":true,"quotaGB":400},"running":{"phase":"Copying","percent":0.42},"schedule":{"frequency":"weekly","weekday":1,"hour":10},"backupRequested":false}"#
        let report = try Report.decoder.decode(Report.self, from: Data(json.utf8))
        #expect(report.disk?.mounted == true && report.disk?.quotaGB == 400)
        #expect(report.running?.text.hasPrefix("Copie · 42") == true)
        #expect(report.schedule == Schedule(frequency: .weekly, weekday: 1, hour: 10))
        let sent = String(decoding: try Report.encoder.encode(report), as: UTF8.self)
        #expect(sent.contains(#""lastBackup":"2026-10-24T09:40:00Z""#))
    }

    @Test func logMessages() {
        let disk = "402F33F2-29EB-482C-9060-BF6A5908BCCC"
        let t0 = Date(timeIntervalSince1970: 1_792_830_000)
        func entry(_ minutes: Double, _ message: String, image: String = TimeMachine.backupd) -> TimeMachine.LogEntry {
            TimeMachine.LogEntry(date: t0.addingTimeInterval(minutes * 60), message: message, image: image)
        }
        func success(_ minutes: Double, from start: Double) -> TimeMachine.Outcome {
            TimeMachine.Outcome(date: t0.addingTimeInterval(minutes * 60), failure: nil, started: t0.addingTimeInterval(start * 60), destination: disk)
        }
        // As logged on 2026-10-24: a request with no disk set, the first backup (chosen in System Settings),
        // then one by rotation, as macOS starts them on its own.
        let log = [
            entry(0, "Backup requested to last destination in rotation. specifiedOptions: TMBackupOptions(rawValue: 18)"),
            entry(0, "Backup failed: BACKUP_FAILED_NO_SUCH_DESTINATION (47)"),
            entry(15, "Backup requested to destination with ID \(disk). specifiedOptions: TMBackupOptions(rawValue: 16)"),
            entry(15, "Mounting destination \(disk) for backing up"),
            entry(16, "Mounting destination \(disk) for browsing"),
            entry(50, "Backup succeeded\nElapsed time: About 35 minutes"),
            entry(62, "Backup requested to next destination in rotation. specifiedOptions: TMBackupOptions(rawValue: 1)"),
            entry(62, "Mounting destination \(disk) for backing up"),
            entry(63, "Backup succeeded\nElapsed time: Less than a minute"),
        ]
        #expect(TimeMachine.outcomes(log, destinations: [disk]) == [success(50, from: 15), success(63, from: 62)])
        // Another disk, another process, or a success with no request before it: not a backup of ours.
        #expect(TimeMachine.outcomes(log, destinations: ["OTHER"]).isEmpty)
        #expect(TimeMachine.outcomes(log.map { entry(0, $0.message, image: "/tmp/backupd") }, destinations: [disk]).isEmpty)
        #expect(TimeMachine.outcomes([entry(50, log[5].message)], destinations: [disk]).isEmpty)
        // A rotation request that never mounted a disk, then « succeeded »: not counted.
        #expect(TimeMachine.outcomes([log[6], entry(63, log[8].message)], destinations: [disk]).isEmpty)
        // As logged at 12:08: « Sauvegarder maintenant » while macOS had just started one. The success counts, the drop is no failure.
        let dropped = [
            entry(70, "Backup requested to next destination in rotation. specifiedOptions: TMBackupOptions(rawValue: 257)"),
            entry(70, "Mounting destination \(disk) for backing up"),
            entry(70.1, "Backup requested to destination with ID \(disk). specifiedOptions: TMBackupOptions(rawValue: 16)"),
            entry(70.1, "Backup failed: BACKUP_IN_PROGRESS_REQUEST_DROPPED (46)"),
            entry(71, "Backup succeeded\nElapsed time: About a minute"),
        ]
        #expect(TimeMachine.outcomes(dropped, destinations: [disk]) == [success(71, from: 70)])
        #expect(TimeMachine.outcomes([log[2], log[3], entry(20, "Backup failed: BACKUP_FAILED_TARGETVOL_NOT_FOUND (18)")], destinations: [disk]).isEmpty)
        // A real failure is kept; the disk being unplugged is not one.
        let full = TimeMachine.outcomes([log[2], log[3], entry(20, "Backup failed: BACKUP_FAILED_DISK_FULL (19)")], destinations: [disk])
        #expect(full.map(\.failure) == ["Plus assez de place sur le disque de sauvegarde."])
        let parsed = TimeMachine.logDate("2026-10-24 10:52:09.042019+0200")
        let expected = ISO8601DateFormatter().date(from: "2026-10-24T08:52:09Z")!
        #expect(parsed.map { abs($0.timeIntervalSince(expected) - 0.042) < 0.01 } == true)
    }
}

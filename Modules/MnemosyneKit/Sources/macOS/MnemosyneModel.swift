import AppKit
import EgideUI
import Foundation
import Observation
import OSLog
import UserNotifications

/// Mnemosyne inside Égide on the Mac: follows Time Machine, keeps the date of the last successful backup
/// (`tmutil latestbackup` needs Full Disk Access, so the date comes from backupd's log), reminds when a backup
/// is due, and sends its state to the Argos server for the iPhone.
@MainActor
@Observable
public final class MnemosyneModel {
    public private(set) var destinations: [TimeMachine.Destination] = []
    public private(set) var status: TimeMachine.Status?
    public private(set) var lastBackup: Date?
    public private(set) var failure: Report.Failure?
    /// Last backups, most recent first, kept here because macOS's log only holds a few days.
    public private(set) var history: [Report.Entry]
    static let historyLength = 50
    public private(set) var notificationsDenied = false
    public var schedule: Schedule {
        didSet {
            guard schedule != oldValue, !EgideDemo.actif else { return }
            Self.save(schedule, "mnemosyne.schedule")
            Task { await refresh() }
        }
    }

    /// Notification action that starts a backup (see `handle(action:)`).
    public static let backupAction = "mnemosyne.backup"
    static let backupCategory = "mnemosyne.reminder.backup"

    private let defaults = UserDefaults.standard
    private let relay = Relay()
    private var started = false
    private var lastLogCheck: Date?
    private var refreshing = false
    private var refreshAgain = false

    public init() {
        if EgideDemo.actif {
            schedule = Schedule(frequency: .weekly, weekday: 1, hour: 20)
            history = Self.demoHistory
            lastBackup = history.first?.end
            destinations = [TimeMachine.Destination(id: "demo", name: "Disque de sauvegarde", mountPoint: nil, quotaGB: 500, isLast: true)]
            return
        }
        schedule = Self.load("mnemosyne.schedule") ?? Schedule()
        lastBackup = defaults.object(forKey: "mnemosyne.lastBackup") as? Date
        failure = Self.load("mnemosyne.failure")
        history = Self.load("mnemosyne.history") ?? []
    }

    /// The disk Time Machine backs up to (the last one used when there are several).
    public var disk: TimeMachine.Destination? { destinations.first(where: \.isLast) ?? destinations.first }
    public var running: Bool { status?.running == true }
    public var due: Date { schedule.due(after: lastBackup) }
    public var canBackUp: Bool { disk?.mountPoint != nil && !running }

    public func start() {
        // Demo mode: fixed data, nothing read from Time Machine, saved, sent or notified.
        guard !started, !EgideDemo.actif else { return }
        started = true
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Self.backupCategory,
                                   actions: [UNNotificationAction(identifier: Self.backupAction, title: "Sauvegarder maintenant")],
                                   intentIdentifiers: []),
        ])
        Task {
            var last = Date.distantPast
            while !Task.isCancelled {
                // Every few seconds while a backup runs, to show its progress, including one started between
                // two rounds (« Sauvegarder maintenant », the iPhone); once a minute otherwise.
                if running || Date.now.timeIntervalSince(last) >= 60 {
                    last = .now
                    await refresh()
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    public func backUpNow() {
        guard canBackUp else { return }
        Task {
            // The disk may have been unplugged since the last refresh (up to a minute ago).
            destinations = await TimeMachine.destinations()
            guard canBackUp, let id = disk?.id else { return }
            await TimeMachine.startBackup(destinationID: id)
            try? await Task.sleep(for: .seconds(2))
            await refresh()
        }
    }

    /// Answer to a notification of Mnemosyne; false when the action belongs to someone else.
    @discardableResult
    public func handle(action: String) -> Bool {
        guard action == Self.backupAction else { return false }
        backUpNow()
        return true
    }

    /// System Settings › General › Time Machine: choosing the disk needs administrator rights, macOS asks for them there.
    public func openTimeMachineSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")!)
    }

    /// Called by the minute loop, a settings change and « Sauvegarder maintenant »: one refresh at a time,
    /// so that the end of a backup is read once.
    func refresh() async {
        if refreshing {
            refreshAgain = true
            return
        }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            await refreshOnce()
        } while refreshAgain
    }

    private func refreshOnce() async {
        let wasRunning = running
        destinations = await TimeMachine.destinations()
        status = await TimeMachine.status()
        // backupd logs the end of each backup, including those macOS starts on its own while Égide is closed.
        let now = Date.now
        let ended = wasRunning && !running
        if ended || lastLogCheck.map({ now.timeIntervalSince($0) > 30 * 60 }) ?? true {
            // At launch and at the end of a backup, its request may be hours old: look a day back for it.
            await readLog(now: now, lookBack: ended || lastLogCheck == nil ? 86_400 : 2 * 3600)
        }
        await remindIfDue(now: now)
        await send()
    }

    private func readLog(now: Date, lookBack: TimeInterval) async {
        // Successes are matched to the configured disks: without them (tmutil not answering), read later.
        guard !destinations.isEmpty else { return }
        // The log keeps a few days: on the first run, read everything it has, and alert about none of it.
        let checkedUntil = defaults.object(forKey: "mnemosyne.logCheckedUntil") as? Date
        // No history yet (first run, or an update that brought it): fill it from all the log has.
        let historyMissing = defaults.data(forKey: "mnemosyne.history") == nil
        let start = (historyMissing ? nil : checkedUntil) ?? now.addingTimeInterval(-30 * 86_400)
        let outcomes = await TimeMachine.outcomes(since: start.addingTimeInterval(-60), lookBack: lookBack,
                                                  destinations: Set(destinations.map(\.id)))
        lastLogCheck = now
        defaults.set(now, forKey: "mnemosyne.logCheckedUntil")
        record(outcomes)
        if let success = outcomes.last(where: { $0.failure == nil }), success.date > (lastBackup ?? .distantPast) {
            lastBackup = success.date
            defaults.set(success.date, forKey: "mnemosyne.lastBackup")
        }
        if let last = outcomes.last(where: { $0.failure != nil }), let reason = last.failure,
           last.date > (lastBackup ?? .distantPast), last.date > (failure?.at ?? .distantPast) {
            failure = Report.Failure(at: last.date, reason: reason)
            Self.save(failure, "mnemosyne.failure")
            // Only a failure the previous read could not have seen is news.
            if let checkedUntil, last.date >= checkedUntil.addingTimeInterval(-60) {
                await notify(title: "Sauvegarde Time Machine échouée", body: reason, id: "mnemosyne.failure", withAction: canBackUp)
                relay.alertPending = last.date
            }
        }
        if let failure, let lastBackup, lastBackup > failure.at {
            self.failure = nil
            Self.save(Report.Failure?.none, "mnemosyne.failure")
        }
    }

    private func record(_ outcomes: [TimeMachine.Outcome]) {
        let names = Dictionary(destinations.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var entries = history
        for outcome in outcomes where !entries.contains(where: { abs($0.end.timeIntervalSince(outcome.date)) < 1 }) {
            entries.append(Report.Entry(start: outcome.started, end: outcome.date, failure: outcome.failure,
                                        disk: outcome.destination.flatMap { names[$0] }))
        }
        entries.sort { $0.end > $1.end }
        entries = Array(entries.prefix(Self.historyLength))
        if entries != history || defaults.data(forKey: "mnemosyne.history") == nil {
            history = entries
            Self.save(entries, "mnemosyne.history")
        }
    }

    /// One reminder on the due date, then the same nudges as on the iPhone (2 and 7 days later).
    private func remindIfDue(now: Date) async {
        guard !running else { return }
        let lastReminder = defaults.object(forKey: "mnemosyne.lastReminder") as? Date ?? .distantPast
        if let lastBackup {
            let past = schedule.reminders(after: lastBackup, now: .distantPast).filter { $0 <= now }
            guard let latest = past.last, lastReminder < latest else { return }
        } else {
            // Never backed up: once a week until it happens.
            guard now.timeIntervalSince(lastReminder) > 7 * 86_400 else { return }
        }
        defaults.set(now, forKey: "mnemosyne.lastReminder")
        let since = lastBackup.map { "Dernière sauvegarde \(Wording.since($0))." } ?? "Aucune sauvegarde pour l'instant."
        let body = canBackUp ? "\(since) Le disque est branché." : "\(since) Branche le disque « \(disk?.name ?? "de sauvegarde") »."
        await notify(title: "Sauvegarde Time Machine à faire", body: body, id: "mnemosyne.reminder", withAction: canBackUp)
    }

    private func notify(title: String, body: String, id: String, withAction: Bool) async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        notificationsDenied = await center.notificationSettings().authorizationStatus == .denied
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if withAction { content.categoryIdentifier = Self.backupCategory }
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func send() async {
        // Within the server's limits (Argos/argos/cmd/server/mnemosyne.go), so a long disk name never gets the report refused.
        let disk = disk.map { Report.Disk(id: String($0.id.prefix(64)), name: String($0.name.prefix(100)), mounted: $0.mountPoint != nil,
                                          quotaGB: $0.quotaGB.map { min(max($0, 0), 999_999) }) }
        let progress = running ? status.map { Report.Progress(phase: String($0.phase.prefix(40)), percent: max(-1, $0.percent)) } : nil
        let report = Report(lastBackup: lastBackup, disk: disk, running: progress, schedule: schedule, failure: failure,
                            history: history.map { entry in
                                var entry = entry
                                entry.failure = entry.failure.map { String($0.prefix(200)) }
                                entry.disk = entry.disk.map { String($0.prefix(100)) }
                                return entry
                            })
        // The iPhone asked for a backup: it only can when the disk was plugged in at the last report.
        if await relay.send(report), canBackUp {
            backUpNow()
        }
    }

    /// One backup a week for six weeks, the last one two days ago.
    private static var demoHistory: [Report.Entry] {
        let day = 86_400.0
        return [2.0, 9, 16, 23.2, 30, 37].enumerated().map { index, daysAgo in
            let end = Date.now.addingTimeInterval(-daysAgo * day)
            return Report.Entry(start: end.addingTimeInterval(-Double(3 + index * 2) * 60), end: end, failure: nil, disk: "Disque de sauvegarde")
        }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func save<T: Encodable>(_ value: T?, _ key: String) {
        UserDefaults.standard.set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }
}

/// Sends the state to this Mac's Argos server, the same way Héphaïstos does (127.0.0.1, agent token).
/// Without Argos installed (no token), nothing is sent.
@MainActor
final class Relay {
    private let logger = Logger(subsystem: "com.spoooke.egide.mac", category: "Mnemosyne")
    private static let address = URL(string: "http://127.0.0.1:8787/api/mnemosyne")!
    private static let token = URL.applicationSupportDirectory.appending(path: "Heartbit/data/agent-token")

    /// Date of a failure to forward to ntfy with the next report.
    var alertPending: Date?
    /// Past this, a failure the server could not take in time is no longer worth a ntfy message.
    static let alertDelay: TimeInterval = 3600

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }()

    /// Returns true when the iPhone asked for a backup.
    func send(_ report: Report) async -> Bool {
        var report = report
        if let pending = alertPending {
            if report.failure?.at == pending, Date.now.timeIntervalSince(pending) < Self.alertDelay {
                report.alert = true
            } else {
                alertPending = nil
            }
        }
        guard let token = try? String(contentsOf: Self.token, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty, let body = try? Report.encoder.encode(report) else { return false }
        var request = URLRequest(url: Self.address)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request) else { return false }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            // A refused report would leave the iPhone without news: say why in the Mac's log.
            logger.error("Argos refused the Mnemosyne report: \((response as? HTTPURLResponse)?.statusCode ?? 0, privacy: .public)")
            return false
        }
        if report.alert == true { alertPending = nil }
        struct Answer: Decodable { var backup: Bool }
        return (try? JSONDecoder().decode(Answer.self, from: data))?.backup ?? false
    }
}

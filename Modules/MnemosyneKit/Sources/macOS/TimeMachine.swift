import Foundation

/// What `tmutil` and the unified log tell without administrator rights or Full Disk Access
/// (tested on macOS 27, see docs/mnemosyne.md). Nothing here changes the Time Machine settings.
public enum TimeMachine {
    public struct Destination: Equatable, Sendable {
        public var id: String
        public var name: String
        public var mountPoint: String?
        public var quotaGB: Int?
        public var isLast: Bool
    }

    public struct Status: Equatable, Sendable {
        public var running: Bool
        public var phase: String
        /// 0 to 1, -1 when unknown.
        public var percent: Double
        public var destinationID: String?
    }

    /// End of a backup, read from backupd's log.
    struct Outcome: Equatable {
        var date: Date
        /// nil when the backup succeeded.
        var failure: String?
        /// When it was requested, if the request is in the log that was read.
        var started: Date? = nil
        /// Time Machine destination ID, when known.
        var destination: String? = nil
    }

    static func destinations() async -> [Destination] {
        guard let plist = await plist("destinationinfo", "-X"),
              let list = plist["Destinations"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let id = item["ID"] as? String else { return nil }
            return Destination(id: id, name: item["Name"] as? String ?? "Disque de sauvegarde",
                               mountPoint: item["MountPoint"] as? String, quotaGB: item["QuotaGB"] as? Int,
                               isLast: (item["LastDestination"] as? Int) == 1)
        }
    }

    static func status() async -> Status? {
        guard let plist = await plist("status", "-X") else { return nil }
        let progress = plist["Progress"] as? [String: Any]
        let percent = progress?["Percent"] as? Double ?? plist["Percent"] as? Double ?? -1
        return Status(running: (plist["Running"] as? Bool) ?? ((plist["Running"] as? Int) == 1),
                      phase: plist["BackupPhase"] as? String ?? "", percent: min(1, percent),
                      destinationID: plist["DestinationID"] as? String)
    }

    /// Same as « Sauvegarder maintenant » in the Time Machine menu. Exits with 0 even when backupd refuses:
    /// the outcome shows in `status` and in the log.
    static func startBackup(destinationID: String?) async {
        var arguments = ["startbackup", "--auto"]
        if let destinationID { arguments += ["--destination", destinationID] }
        _ = await run("/usr/bin/tmutil", arguments)
    }

    /// One line of backupd's log.
    struct LogEntry: Equatable {
        var date: Date
        var message: String
        var image: String
    }

    static let backupd = "/System/Library/CoreServices/TimeMachine/backupd"

    /// Backups that ended since `start` on one of `destinations`, oldest first.
    /// `lookBack`: how far before `start` to look for the request of a backup that was already running at `start`.
    static func outcomes(since start: Date, lookBack: TimeInterval, destinations: Set<String>) async -> [Outcome] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
        let predicate = #"subsystem == "com.apple.TimeMachine" AND process == "backupd" AND (category == "BackupDispatching" OR "#
            + #"(category == "MountedDestinationManager" AND eventMessage BEGINSWITH "Mounting destination "))"#
        guard let output = await run("/usr/bin/log", ["show", "--info", "--style", "ndjson",
                                                      "--start", formatter.string(from: start.addingTimeInterval(-lookBack)),
                                                      "--predicate", predicate]) else { return [] }
        let entries: [LogEntry] = output.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = entry["eventMessage"] as? String,
                  let stamp = entry["timestamp"] as? String,
                  let date = logDate(stamp) else { return nil }
            return LogEntry(date: date, message: message, image: entry["processImagePath"] as? String ?? "")
        }
        return outcomes(entries, destinations: destinations).filter { $0.date >= start }
    }

    /// Reads backupd's messages, as seen on macOS 27. One backup at a time, in this order:
    /// « Backup requested to destination with ID <id>. … » (from System Settings or `--destination`)
    /// or « Backup requested to next destination in rotation. … » (macOS on its own, `tmutil startbackup --auto`);
    /// then « Mounting destination <id> for backing up »; then « Backup succeeded\nElapsed time: … »
    /// or « Backup failed: BACKUP_FAILED_… (47) ».
    /// A success counts only when its backup went to one of `destinations`: any process may write to this
    /// subsystem, and a « succeeded » that is not ours must never make the Mac look backed up.
    /// A missing disk is not a failure: with a disk plugged in by hand, it is the usual state. Nor is a request
    /// dropped because a backup already runs (« BACKUP_IN_PROGRESS_REQUEST_DROPPED »): the running one carries on.
    static func outcomes(_ entries: [LogEntry], destinations: Set<String>) -> [Outcome] {
        // Disk of the backup in progress: "" once requested, its ID once known.
        var current: String?
        var started: Date?
        var outcomes: [Outcome] = []
        for entry in entries where entry.image == backupd {
            let message = entry.message
            if message.hasPrefix("Backup requested to ") {
                // A request made while a backup runs is dropped by backupd: keep the running one.
                if current == nil {
                    current = destinationID(after: "Backup requested to destination with ID ", in: message) ?? ""
                    started = entry.date
                }
            } else if let id = destinationID(after: "Mounting destination ", in: message), message.hasSuffix(" for backing up") {
                if current == "" { current = id }
            } else if message == "Backup succeeded" || message.hasPrefix("Backup succeeded\n") {
                if let current, destinations.contains(current) {
                    outcomes.append(Outcome(date: entry.date, failure: nil, started: started, destination: current))
                }
                current = nil
                started = nil
            } else if message.hasPrefix("Backup failed") {
                if message.contains("REQUEST_DROPPED") { continue }
                if !destinationMissing(message) {
                    outcomes.append(Outcome(date: entry.date, failure: failureText(message), started: started,
                                            destination: current?.isEmpty == false ? current : nil))
                }
                current = nil
                started = nil
            }
        }
        return outcomes
    }

    private static func destinationID(after prefix: String, in message: String) -> String? {
        guard message.hasPrefix(prefix) else { return nil }
        let id = message.dropFirst(prefix.count).prefix { $0.isHexDigit || $0 == "-" }
        return id.isEmpty ? nil : String(id)
    }

    private static func destinationMissing(_ message: String) -> Bool {
        // TARGETVOL_NOT_FOUND: a backup requested just as the disk was unplugged.
        ["NO_SUCH_DESTINATION", "DESTINATION_UNAVAILABLE", "TARGETVOL_NOT_FOUND"].contains { message.contains($0) }
    }

    static func failureText(_ message: String) -> String {
        switch message {
        case let m where m.contains("NOT_ENOUGH_SPACE") || m.contains("DISK_FULL"): "Plus assez de place sur le disque de sauvegarde."
        case let m where m.contains("CANCELED") || m.contains("CANCELLED"): "Sauvegarde annulée."
        default:
            // « BACKUP_FAILED_XYZ (12) » stays readable enough, and gives something to search for.
            String(message.replacingOccurrences(of: "Backup failed: ", with: "").prefix(150))
        }
    }

    /// log's ndjson timestamps look like « 2026-10-24 11:07:31.775000+0200 ».
    static func logDate(_ stamp: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return formatter.date(from: stamp)
    }

    private static func plist(_ arguments: String...) async -> [String: Any]? {
        guard let output = await run("/usr/bin/tmutil", arguments), let data = output.data(using: .utf8) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// Runs a command off the main thread and returns what it printed.
    private static func run(_ path: String, _ arguments: [String]) async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        }.value
    }
}

import EgideUI
import SwiftUI
import UserNotifications

/// Mnemosyne's tab in Égide on the iPhone: the Mac's last Time Machine backup, read from the Argos server
/// (Égide on the Mac sends it once a minute). The reminder is a local notification, scheduled here from the
/// last known backup, so that it shows up even when the Mac is off.
public enum MnemosyneKit {
    public static let title = "Mnémosyne"
    public static let systemImage = "clock.arrow.circlepath"

    /// Call to the Argos server (path, method, JSON body), plugged by the app into Argos's connection (EgideApp);
    /// returns nil when Argos is not connected.
    @MainActor public static var server: @MainActor @Sendable (String, String, Data?) async throws -> Data? = { _, _, _ in nil }

    /// Last report received, kept for when the Mac is off.
    static var cached: Report? {
        get { UserDefaults.standard.data(forKey: "mnemosyne.report").flatMap { try? Report.decoder.decode(Report.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? Report.encoder.encode($0) }, forKey: "mnemosyne.report") }
    }

    /// nil when Argos is not connected.
    @MainActor
    static func load() async throws -> Report? {
        guard let data = try await server("api/mnemosyne", "GET", nil) else { return nil }
        let report = try Report.decoder.decode(Report.self, from: data)
        if report.at != nil {
            cached = report
            await Reminders.schedule(report)
        }
        return report
    }

    @MainActor
    static func requestBackup() async throws {
        _ = try await server("api/mnemosyne/backup", "POST", nil)
    }
}

/// Local notifications: on the due date, then 2 and 7 days later if still no backup.
/// Rescheduled when the last backup, the schedule or the disk changes, so a backup done in the meantime cancels them.
enum Reminders {
    static let ids = (0..<3).map { "mnemosyne.reminder.\($0)" }
    private static let scheduledKey = "mnemosyne.remindersFor"

    @MainActor
    static func schedule(_ report: Report, askPermission: Bool = false) async {
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if askPermission, status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            status = await center.notificationSettings().authorizationStatus
        }
        let disk = report.disk?.name ?? "de sauvegarde"
        let defaults = UserDefaults.standard
        guard status == .authorized || status == .provisional, let lastBackup = report.lastBackup else {
            center.removePendingNotificationRequests(withIdentifiers: ids)
            defaults.removeObject(forKey: scheduledKey)
            return
        }
        let key = "\(lastBackup.timeIntervalSince1970)|\(report.schedule.frequency.rawValue)|\(report.schedule.weekday)|\(report.schedule.hour)|\(disk)"
        guard defaults.string(forKey: scheduledKey) != key else { return }
        defaults.set(key, forKey: scheduledKey)
        center.removePendingNotificationRequests(withIdentifiers: ids)
        for (id, date) in zip(ids, report.schedule.reminders(after: lastBackup)) {
            let content = UNMutableNotificationContent()
            content.title = "Sauvegarde Time Machine à faire"
            content.body = "Dernière sauvegarde du Mac le \(Wording.dayAndMonth(lastBackup)). Branche le disque « \(disk) » sur le Mac."
            content.sound = .default
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            try? await center.add(UNNotificationRequest(identifier: id, content: content,
                                                        trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
        }
    }
}

/// Root screen of the tab.
public struct MnemosyneRootView: View {
    private enum Phase: Equatable {
        case loading
        case notConnected
        case failed(String)
        case received(Report)
    }

    private let onHome: (@MainActor @Sendable () -> Void)?
    @State private var phase = Phase.loading
    @State private var requested = false
    @State private var requestError: String?

    /// `onHome`: « Précédent » button back to Égide's home screen.
    public init(path: [String] = [], request: Int = 0, onHome: (@MainActor @Sendable () -> Void)? = nil) {
        self.onHome = onHome
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    switch phase {
                    case .loading:
                        ProgressView().padding(.top, 60)
                    case .notConnected:
                        message("Argos n'est pas connecté", "Les sauvegardes du Mac passent par le serveur Argos : connecte d'abord l'app Argos d'Égide.")
                    case .failed(let text):
                        if let cached = MnemosyneKit.cached {
                            content(cached, offline: true)
                        } else {
                            message("Mac injoignable", text)
                        }
                    case .received(let report):
                        if report.at == nil {
                            message("Rien reçu du Mac", "Ouvre Égide sur le Mac : c'est lui qui suit Time Machine.")
                        } else {
                            content(report, offline: false)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .egideScreen()
            .foregroundStyle(EgideTheme.encre)
            .navigationTitle(MnemosyneKit.title)
            .toolbar { HomeToolbarItem(action: onHome) }
            .refreshable { await reload() }
            .task {
                await reload()
                // First visit: ask for notifications here, where the reminder is explained.
                if let cached = MnemosyneKit.cached { await Reminders.schedule(cached, askPermission: true) }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(requested || running ? 5 : 30))
                    await reload()
                }
            }
        }
    }

    private var running: Bool {
        if case .received(let report) = phase { return report.running != nil }
        return false
    }

    private func reload() async {
        do {
            guard let report = try await MnemosyneKit.load() else {
                phase = .notConnected
                return
            }
            if report.running != nil || report.backupRequested != true { requested = false }
            phase = .received(report)
        } catch is CancellationError {
        } catch {
            if case .received = phase { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func message(_ title: String, _ text: String) -> some View {
        ContentUnavailableView(title, systemImage: MnemosyneKit.systemImage, description: Text(text))
            .padding(.top, 40)
    }

    @ViewBuilder
    private func content(_ report: Report, offline: Bool) -> some View {
        let overdue = report.lastBackup != nil && report.due <= .now
        VStack(alignment: .leading, spacing: 8) {
            Text("Dernière sauvegarde du Mac").font(.subheadline).foregroundStyle(.secondary)
            Text(report.lastBackup.map { Wording.since($0).capitalizedFirst } ?? "Aucune pour l'instant")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(overdue ? .orange : EgideTheme.encre)
            if let lastBackup = report.lastBackup {
                Text(lastBackup.formatted(date: .long, time: .shortened)).font(.footnote).foregroundStyle(.secondary)
            }
            if report.running == nil, let failure = report.failure {
                Label("Échec \(Wording.since(failure.at)) : \(failure.reason)", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Divider().padding(.vertical, 4)
            Text("Prochaine").font(.subheadline).foregroundStyle(.secondary)
            Text(report.running != nil ? "En cours" : Wording.due(report.due).capitalizedFirst).font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .egideCard(padding: 18)

        VStack(alignment: .leading, spacing: 10) {
            if let disk = report.disk {
                HStack {
                    Image(systemName: disk.mounted ? "externaldrive.fill" : "externaldrive")
                        .foregroundStyle(disk.mounted ? EgideTheme.bleu : Color.secondary)
                    Text(disk.name).font(.body.weight(.medium))
                    Spacer()
                    Text(disk.mounted ? "branché" : "débranché").foregroundStyle(.secondary)
                }
            } else {
                Text("Aucun disque réglé dans Time Machine sur le Mac.").foregroundStyle(.secondary)
            }
            if let progress = report.running {
                Text("Sauvegarde en cours · \(progress.text)").font(.callout).monospacedDigit()
                if progress.percent >= 0 { ProgressView(value: progress.percent) }
            } else if report.disk?.mounted == true, !offline, fresh(report) {
                Button(requested ? "Demandé au Mac…" : "Sauvegarder maintenant", systemImage: "clock.arrow.circlepath") {
                    Task { await askBackup() }
                }
                .buttonStyle(.egide)
                .disabled(requested)
            }
            if let requestError {
                Text(requestError).font(.footnote).foregroundStyle(.red)
            }
            if let at = report.at {
                Text(offline ? "Mac injoignable, état \(Wording.since(at))" : "Vu sur le Mac \(Wording.since(at))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .egideCard()

        if let history = report.history {
            HistoryList(history: history, schedule: report.schedule)
                .egideCard()
        }

        VStack(alignment: .leading, spacing: 6) {
            EgideSectionTitle("Rappel")
            Text("\(report.schedule.text), à \(report.schedule.hour) h")
            Text("Compté depuis la dernière sauvegarde réussie. Se règle dans Égide sur le Mac.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .egideCard()
    }

    /// The button only makes sense when the Mac reported a moment ago.
    private func fresh(_ report: Report) -> Bool {
        report.at.map { Date.now.timeIntervalSince($0) < 180 } ?? false
    }

    private func askBackup() async {
        requestError = nil
        do {
            try await MnemosyneKit.requestBackup()
            requested = true
        } catch {
            requestError = "Le Mac n'a pas pu lancer la sauvegarde : \(error.localizedDescription)"
        }
    }
}

// App services: line under the home tile, global backup.
extension MnemosyneKit {
    /// « Sauvegardé il y a 3 jours » (nil when Argos is not connected and nothing was ever received).
    /// Also refreshes the reminders each time Égide opens.
    @MainActor
    public static func summary() async -> String? {
        // Nothing received from the Mac yet: nothing to say.
        guard let report = (try? await load()) ?? cached, report.at != nil else { return nil }
        if report.running != nil { return "Sauvegarde en cours" }
        guard let lastBackup = report.lastBackup else { return "Aucune sauvegarde" }
        return report.due <= .now ? "Sauvegarde à faire" : "Sauvegardé \(Wording.since(lastBackup))"
    }

    /// Nothing to back up: everything lives on the Mac.
    @MainActor
    public static func backup() throws -> Data? { nil }

    @MainActor
    public static func restore(_ data: Data) throws -> String { "rien à restaurer" }
}

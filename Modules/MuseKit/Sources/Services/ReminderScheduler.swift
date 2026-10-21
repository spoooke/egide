#if os(iOS) && !targetEnvironment(macCatalyst)
import AlarmKit
#endif
import Foundation
import SwiftUI
import UserNotifications

/// Programme et annule les rappels côté système.
/// Protocole pour pouvoir le remplacer par un faux dans les tests.
@MainActor
protocol ReminderScheduling {
    func schedule(id: UUID, text: String, date: Date, kind: ReminderKind) async throws
    func cancel(id: UUID)
}

#if os(iOS) && !targetEnvironment(macCatalyst)
struct IdeaAlarmMetadata: AlarmMetadata {}
#endif

struct SystemReminderScheduler: ReminderScheduling {
    func schedule(id: UUID, text: String, date: Date, kind: ReminderKind) async throws {
        switch kind {
        case .notification: try await scheduleNotification(id: id, text: text, date: date)
        case .alarm: try await scheduleAlarm(id: id, text: text, date: date)
        }
    }

    func cancel(id: UUID) {
        // On ne sait pas forcément quel type était programmé : on annule les deux.
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        #if os(iOS) && !targetEnvironment(macCatalyst)
        try? AlarmManager.shared.cancel(id: id)
        #endif
    }

    private func scheduleNotification(id: UUID, text: String, date: Date) async throws {
        let center = UNUserNotificationCenter.current()
        guard try await center.requestAuthorization(options: [.alert, .sound]) else {
            throw ReminderError.notAuthorized(.notification)
        }

        let content = UNMutableNotificationContent()
        content.title = "Idée"
        content.body = text
        content.sound = .default

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try await center.add(UNNotificationRequest(identifier: id.uuidString, content: content, trigger: trigger))
    }

    private func scheduleAlarm(id: UUID, text: String, date: Date) async throws {
        #if !(os(iOS) && !targetEnvironment(macCatalyst))
        throw ReminderError.notAuthorized(.alarm)
        #else
        let manager = AlarmManager.shared
        guard try await manager.requestAuthorization() == .authorized else {
            throw ReminderError.notAuthorized(.alarm)
        }

        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(String.LocalizationValue(text)),
            stopButton: AlarmButton(text: "Arrêter", textColor: .white, systemImageName: "stop.circle")
        )
        let attributes = AlarmAttributes<IdeaAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            tintColor: .orange
        )
        _ = try await manager.schedule(id: id, configuration: .alarm(schedule: .fixed(date), attributes: attributes))
        #endif
    }
}

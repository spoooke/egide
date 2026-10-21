import Foundation

enum ReminderKind: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Notification classique : bannière + son, respecte le mode silencieux.
    case notification
    /// Vraie alarme (AlarmKit) : sonne en plein écran, même en mode silencieux.
    case alarm

    var id: Self { self }

    /// AlarmKit n'existe pas sur Mac : uniquement les notifications.
    static var available: [ReminderKind] {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        allCases
        #else
        [.notification]
        #endif
    }

    var label: String {
        switch self {
        case .notification: "Notification"
        case .alarm: "Alarme"
        }
    }

    var systemImage: String {
        switch self {
        case .notification: "bell"
        case .alarm: "alarm"
        }
    }
}

enum ReminderError: LocalizedError, Equatable {
    case notAuthorized(ReminderKind)
    case dateInPast

    var errorDescription: String? {
        switch self {
        case .notAuthorized(.notification):
            "Les notifications sont désactivées. Autorise-les dans Réglages › Muse."
        case .notAuthorized(.alarm):
            "Les alarmes sont désactivées. Autorise-les dans Réglages › Muse."
        case .dateInPast:
            "Choisis une heure dans le futur."
        }
    }
}

/// Raccourcis pour régler un rappel en un geste.
enum ReminderPreset: CaseIterable, Identifiable {
    case inOneHour
    case tonight
    case tomorrowMorning

    var id: Self { self }

    var label: String {
        switch self {
        case .inOneHour: "Dans 1 h"
        case .tonight: "Ce soir 20 h"
        case .tomorrowMorning: "Demain 9 h"
        }
    }

    /// Date du raccourci, ou `nil` s'il n'a plus de sens (« Ce soir » une fois 20 h passées).
    func date(from now: Date = .now, calendar: Calendar = .current) -> Date? {
        switch self {
        case .inOneHour:
            // À la minute près, comme le déclenchement des rappels.
            let inOneHour = now.addingTimeInterval(3600)
            return calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: inOneHour))
        case .tonight:
            guard let tonight = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now),
                  tonight > now else { return nil }
            return tonight
        case .tomorrowMorning:
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
        }
    }
}

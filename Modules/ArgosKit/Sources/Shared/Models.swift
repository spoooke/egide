import Foundation

// Miroir des structures JSON du serveur Go (cmd/server et internal/model).

enum CheckStatus: String, Codable, CaseIterable {
    case pass, warn, fail, unknown

    init(from decoder: Decoder) throws {
        self = CheckStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    var label: String {
        switch self {
        case .pass: "OK"
        case .warn: "À surveiller"
        case .fail: "À corriger"
        case .unknown: "À vérifier"
        }
    }

    // Ordre d'affichage : les problèmes d'abord.
    var rank: Int {
        switch self {
        case .fail: 0
        case .warn: 1
        case .unknown: 2
        case .pass: 3
        }
    }
}

enum Severity: String, Codable {
    case low, medium, high, critical

    init(from decoder: Decoder) throws {
        self = Severity(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .low
    }

    var label: String {
        switch self {
        case .low: "faible"
        case .medium: "moyenne"
        case .high: "élevée"
        case .critical: "critique"
        }
    }
}

struct Check: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let category: String
    let status: CheckStatus
    let severity: Severity
    let detail: String?
    let fix: String?
    let how: String?
    let link: String?
}

/// Risque accepté : problème connu que l'on a décidé de ne pas corriger. Il compte toujours
/// dans le score, mais n'alerte plus ; la décision est à confirmer à la date de révision.
struct Acceptance: Codable, Hashable {
    let reason: String
    let at: Date
    let reviewAt: Date

    var isDue: Bool { reviewAt <= Date() }
}

struct Report: Codable, Hashable {
    let deviceId: String
    let hostname: String
    let os: String
    let osVersion: String
    let arch: String?
    let agentVersion: String?
    let collectedAt: Date?
    let checks: [Check]
    let score: Int
    let updatesCheckedAt: Date?
    let health: Health?
}

/// État matériel envoyé par l'agent (sans effet sur le score de sécurité).
struct Health: Codable, Hashable {
    let cpuPercent: Int
    let cpuCores: Int
    let memTotal: UInt64
    let memUsed: UInt64
    let diskTotal: UInt64
    let diskFree: UInt64
    let battery: Battery?

    var memPercent: Int { memTotal > 0 ? Int(memUsed * 100 / memTotal) : 0 }
    var diskPercent: Int { diskTotal > 0 && diskFree <= diskTotal ? Int((diskTotal - diskFree) * 100 / diskTotal) : 0 }

    var summary: String {
        var parts = ["Processeur \(cpuPercent) %", "RAM \(memPercent) %", "Disque \(diskPercent) %"]
        if let battery { parts.append("Batterie \(battery.percent) %") }
        return parts.joined(separator: " · ")
    }
}

struct Battery: Codable, Hashable {
    let percent: Int
    let charging: Bool
    let plugged: Bool
    let healthPercent: Int?
    let cycles: Int?
}

struct ScorePoint: Codable, Hashable {
    let at: Date
    let score: Int
}

struct DeviceDetail: Codable, Hashable {
    let kind: String
    let lastSeen: Date
    let online: Bool
    let updateRequestedAt: Date?
    let scanRequestedAt: Date?

    /// Scan demandé mais pas encore reçu (l'ordinateur le reçoit à son prochain signal, 30 s au plus).
    var isScanning: Bool {
        guard let req = scanRequestedAt?.meaningful else { return false }
        return req > (latest.collectedAt ?? .distantPast) && Date().timeIntervalSince(req) < 120
    }
    let remoteIp: String?
    let latest: Report
    let history: [ScorePoint]?
    let accepted: [String: Acceptance]?

    var isManual: Bool { kind == "manual" }

    /// Acceptation en cours pour ce contrôle (jamais pour un point revenu à OK).
    func acceptance(of check: Check) -> Acceptance? {
        check.status == .pass ? nil : accepted?[check.id]
    }
}

struct DeviceSummary: Codable, Identifiable, Hashable {
    let id: String
    let kind: String
    let hostname: String
    let os: String
    let osVersion: String
    let score: Int
    let lastSeen: Date
    let online: Bool
    let counts: [String: Int]
    let health: Health?

    var isManual: Bool { kind == "manual" }
    var fails: Int { counts["fail"] ?? 0 }
    var warns: Int { counts["warn"] ?? 0 }
    var unknowns: Int { counts["unknown"] ?? 0 }
    var accepted: Int { counts["accepted"] ?? 0 }

    // Un ordinateur envoie un signal toutes les 30 s ; une checklist se refait tous les 3 mois.
    var isStale: Bool {
        Date().timeIntervalSince(lastSeen) > (isManual ? 90 * 86400 : 86400)
    }
}

struct ServerSettings: Codable, Equatable {
    var ntfyServer: String
    var ntfyTopic: String
    var dashboardUrl: String
}

enum Platform {
    static func name(_ os: String) -> String {
        switch os {
        case "darwin": "macOS"
        case "windows": "Windows"
        case "linux": "Linux"
        case "ios": "iOS"
        case "android": "Android"
        default: os
        }
    }

    static func symbol(_ os: String) -> String {
        switch os {
        case "darwin": "laptopcomputer"
        case "ios": "iphone"
        case "android": "smartphone"
        default: "pc"
        }
    }
}

extension Date {
    /// Le serveur envoie l'année 1 pour « jamais » : on la traite comme absente.
    var meaningful: Date? { timeIntervalSince1970 > 0 ? self : nil }
}

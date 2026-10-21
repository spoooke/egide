import EgideUI
import Foundation

/// Mode démo d'Égide : un petit parc inventé, sans aucun appel au serveur.
enum DemoArgos {
    static var actif: Bool { EgideDemo.actif }

    /// Adresse qui ne mène nulle part : les écrans de détail échouent proprement au lieu de joindre un vrai serveur.
    static let connexion = Connection(baseURL: URL(string: "https://demo.invalid")!, token: "demo")

    static var appareils: [DeviceSummary] {
        let go: UInt64 = 1_073_741_824
        func sante(_ cpu: Int, _ ram: UInt64, _ disque: UInt64, batterie: Int?) -> Health {
            Health(cpuPercent: cpu, cpuCores: 10, memTotal: 16 * go, memUsed: ram * go, diskTotal: 512 * go, diskFree: disque * go,
                   battery: batterie.map { Battery(percent: $0, charging: false, plugged: true, healthPercent: 91, cycles: 214) })
        }
        return [
            DeviceSummary(id: "demo-mac", kind: "agent", hostname: "MacBook-Atelier", os: "darwin", osVersion: "macOS 26.1",
                          score: 96, lastSeen: .now, online: true, counts: ["warn": 1], health: sante(18, 9, 210, batterie: 84)),
            DeviceSummary(id: "demo-pc", kind: "agent", hostname: "PC-Comptoir", os: "windows", osVersion: "Windows 11 Pro 24H2",
                          score: 78, lastSeen: .now.addingTimeInterval(-600), online: true, counts: ["fail": 1, "warn": 2],
                          health: sante(35, 11, 96, batterie: nil)),
            DeviceSummary(id: "demo-mini", kind: "agent", hostname: "Mac-mini-Bureau", os: "darwin", osVersion: "macOS 26.0",
                          score: 100, lastSeen: .now.addingTimeInterval(-4 * 3600), online: false, counts: [:], health: sante(4, 6, 380, batterie: nil)),
            DeviceSummary(id: "demo-iphone", kind: "manual", hostname: "iPhone-Demo", os: "ios", osVersion: "iOS 26.1",
                          score: 90, lastSeen: .now.addingTimeInterval(-9 * 86400), online: false, counts: ["warn": 1], health: nil),
        ]
    }
}

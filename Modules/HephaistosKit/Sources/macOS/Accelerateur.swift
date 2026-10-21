import Foundation
import IOKit

/// Utilisation de la puce graphique, publiée par son pilote dans le registre d'IOKit (sans mot de passe administrateur).
/// Le pilote tient lui-même une moyenne : une seule lecture suffit, sans attente entre deux relevés.
final class Accelerateur {
    private var service: io_service_t = 0

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    func lire() -> CarteGraphique? {
        if service == 0 { service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator")) }
        guard service != 0 else { return nil }
        guard let statistiques = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any] else {
            // Pilote relancé : le service sera cherché de nouveau à la prochaine lecture.
            IOObjectRelease(service)
            service = 0
            return nil
        }
        return Self.carte(statistiques)
    }

    static func carte(_ statistiques: [String: Any]) -> CarteGraphique? {
        guard let pourcentage = (statistiques["Device Utilization %"] as? NSNumber)?.doubleValue else { return nil }
        let memoire = (statistiques["In use system memory"] as? NSNumber)?.doubleValue ?? 0
        return CarteGraphique(utilisation: min(1, max(0, pourcentage / 100)), memoire: max(0, memoire))
    }
}

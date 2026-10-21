import Darwin
import Foundation

/// Mémoire vive et disque du Mac : des questions posées au système, sans mot de passe administrateur.
enum Ressources {
    /// Nombre d'apps montrées dans le classement de la mémoire.
    static let nombreApps = 3

    static func memoire() -> Memoire? {
        var stats = vm_statistics64()
        var taille = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let retour = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(taille)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &taille)
            }
        }
        guard retour == KERN_SUCCESS else { return nil }
        var niveau: Int32 = 0
        var octets = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &niveau, &octets, nil, 0)
        return memoire(interne: UInt64(stats.internal_page_count), purgeable: UInt64(stats.purgeable_count),
                       reservee: UInt64(stats.wire_count), compressee: UInt64(stats.compressor_page_count),
                       page: UInt64(getpagesize()), totale: ProcessInfo.processInfo.physicalMemory, niveau: niveau)
    }

    /// Compteurs du système, en pages. Mémoire utilisée, comme dans le Moniteur d'activité : celle des apps
    /// (pages internes, moins celles que le système peut reprendre), la mémoire réservée et la mémoire compressée.
    /// `niveau` : 1 = pression normale, 2 = élevée, 4 = critique.
    static func memoire(interne: UInt64, purgeable: UInt64, reservee: UInt64, compressee: UInt64, page: UInt64, totale: UInt64, niveau: Int32) -> Memoire {
        let pages = (interne > purgeable ? interne - purgeable : 0) + reservee + compressee
        let pression: Pression = niveau >= 4 ? .critique : niveau >= 2 ? .elevee : .normale
        return Memoire(utilisee: min(Double(pages * page), Double(totale)), totale: Double(totale), pression: pression)
    }

    static func disque() -> Disque? {
        let valeurs = try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        guard let libre = valeurs?.volumeAvailableCapacityForImportantUsage, let total = valeurs?.volumeTotalCapacity, total > 0 else { return nil }
        return Disque(libre: Double(libre), total: Double(total))
    }

    /// Les apps qui occupent le plus de mémoire, de la plus grosse à la plus petite. Un seul relevé, sans attente.
    /// `apps` : apps ouvertes (identifiant de processus → nom).
    static func apps(_ apps: [pid_t: String]) -> [Occupation] {
        var processus: [pid_t: Gourmands.Processus] = [:]
        for pid in Gourmands.pids() {
            guard let usage = Gourmands.usage(pid) else { continue }
            processus[pid] = .init(nom: Gourmands.nom(pid), parent: Gourmands.parent(pid), responsable: Gourmands.responsable(pid),
                                   temps: Double(usage.ri_phys_footprint))
        }
        return classement(processus, apps: apps)
    }

    /// Regroupe les processus par app, comme pour le processeur, et garde les plus grosses.
    static func classement(_ processus: [pid_t: Gourmands.Processus], apps: [pid_t: String]) -> [Occupation] {
        let (parApp, parNom) = Gourmands.regrouper(processus, apps: apps)
        let toutes = parApp.map { Occupation(nom: apps[$0.key] ?? "", octets: $0.value) } + parNom.map { Occupation(nom: $0.key, octets: $0.value) }
        return Array(toutes.filter { $0.octets > 0 }.sorted { ($0.octets, $1.nom) > ($1.octets, $0.nom) }.prefix(nombreApps))
    }
}

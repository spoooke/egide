import Darwin

/// Charge du processeur (tous cœurs confondus) entre deux lectures, de 0 à 1.
struct ChargeProcesseur {
    struct Compteurs: Equatable {
        var actif: UInt64
        var total: UInt64
    }

    private var precedent: Compteurs?

    mutating func lire() -> Double? {
        guard let actuel = Self.compteurs() else { return nil }
        defer { precedent = actuel }
        return precedent.flatMap { Self.part(avant: $0, apres: actuel) }
    }

    /// Part du temps passée hors repos entre deux relevés des compteurs (nil si rien n'a avancé).
    static func part(avant: Compteurs, apres: Compteurs) -> Double? {
        guard apres.total > avant.total, apres.actif >= avant.actif else { return nil }
        return min(1, Double(apres.actif - avant.actif) / Double(apres.total - avant.total))
    }

    private static func compteurs() -> Compteurs? {
        var info = host_cpu_load_info()
        var taille = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let retour = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(taille)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &taille)
            }
        }
        guard retour == KERN_SUCCESS else { return nil }
        // cpu_ticks : utilisateur, système, repos, basse priorité.
        let (utilisateur, systeme, repos, bassePriorite) = info.cpu_ticks
        let actif = UInt64(utilisateur) + UInt64(systeme) + UInt64(bassePriorite)
        return Compteurs(actif: actif, total: actif + UInt64(repos))
    }
}

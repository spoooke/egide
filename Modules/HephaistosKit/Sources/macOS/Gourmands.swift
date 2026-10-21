import Darwin
import Foundation

/// Ce qu'une app consomme de processeur, ses processus auxiliaires compris.
public struct Consommation: Equatable, Sendable {
    public var nom: String
    /// En cœurs : 1 = un cœur entier.
    public var coeurs: Double
    public var auPremierPlan: Bool

    public init(nom: String, coeurs: Double, auPremierPlan: Bool = false) {
        self.nom = nom
        self.coeurs = coeurs
        self.auPremierPlan = auPremierPlan
    }

    public var texte: String {
        "\(Int((coeurs * 100).rounded())) % d'un cœur"
    }
}

/// Apps qui consomment le plus de processeur. Mesuré seulement au moment d'une alerte (deux relevés à une
/// seconde d'écart) : rien ne tourne le reste du temps.
/// Sans mot de passe administrateur, seuls les processus de la session sont lisibles : ceux du système
/// (WindowServer, kernel_task) n'apparaissent pas.
public enum Gourmands {
    /// Un processus et ce qu'il a consommé entre les deux relevés.
    struct Processus: Equatable {
        var nom: String
        var parent: pid_t
        /// Processus dont il dépend d'après le système (l'app, pour un auxiliaire lancé à part) ; 0 si inconnu.
        var responsable: pid_t = 0
        /// Secondes de processeur consommées (ou octets de mémoire occupés, pour `Ressources.apps`).
        var temps: Double
    }

    /// Secondes entre les deux relevés.
    static let attente = 1.0

    /// `apps` : apps ouvertes (identifiant de processus → nom) ; `premierPlan` : celle qui est à l'écran.
    public static func mesurer(apps: [pid_t: String], premierPlan: pid_t?) async -> [Consommation] {
        let avant = temps()
        let debut = ContinuousClock.now
        try? await Task.sleep(for: .seconds(attente))
        let apres = temps()
        let ecoule = ContinuousClock.now - debut
        let secondes = Double(ecoule.components.seconds) + Double(ecoule.components.attoseconds) / 1e18
        var processus: [pid_t: Processus] = [:]
        for (pid, total) in apres {
            guard let depart = avant[pid], total >= depart else { continue }
            processus[pid] = Processus(nom: nom(pid), parent: parent(pid), responsable: responsable(pid), temps: total - depart)
        }
        return classement(processus, secondes: secondes, apps: apps, premierPlan: premierPlan)
    }

    /// Regroupe les processus par app et classe de la plus gourmande à la moins gourmande.
    /// Un processus est rattaché à l'app dont il dépend, sinon à la première app trouvée en remontant ses
    /// parents, sinon il compte sous son propre nom.
    static func classement(_ processus: [pid_t: Processus], secondes: Double, apps: [pid_t: String], premierPlan: pid_t?) -> [Consommation] {
        guard secondes > 0 else { return [] }
        let (parApp, parNom) = regrouper(processus, apps: apps)
        let desApps = parApp.map { Consommation(nom: apps[$0.key] ?? "", coeurs: $0.value / secondes, auPremierPlan: $0.key == premierPlan) }
        let autres = parNom.map { Consommation(nom: $0.key, coeurs: $0.value / secondes) }
        return (desApps + autres).filter { $0.coeurs > 0 }.sorted { ($0.coeurs, $1.nom) > ($1.coeurs, $0.nom) }
    }

    /// Additionne les processus par app (identifiant de l'app → total), et par nom pour ceux qui ne dépendent d'aucune app.
    static func regrouper(_ processus: [pid_t: Processus], apps: [pid_t: String]) -> (parApp: [pid_t: Double], parNom: [String: Double]) {
        func app(_ pid: pid_t) -> pid_t? {
            if let responsable = processus[pid]?.responsable, apps[responsable] != nil { return responsable }
            var courant = pid
            // Borne : une chaîne de parents ne dépasse jamais quelques maillons.
            for _ in 0..<16 {
                if apps[courant] != nil { return courant }
                guard let suivant = processus[courant]?.parent, suivant > 1 else { return nil }
                courant = suivant
            }
            return nil
        }
        var parApp: [pid_t: Double] = [:]
        var parNom: [String: Double] = [:]
        for (pid, un) in processus {
            if let proprietaire = app(pid) { parApp[proprietaire, default: 0] += un.temps } else { parNom[un.nom, default: 0] += un.temps }
        }
        return (parApp, parNom)
    }

    /// Secondes de processeur consommées par chaque processus lisible depuis son lancement.
    private static func temps() -> [pid_t: Double] {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        // Les compteurs sont en unités d'horloge de la puce, à convertir en secondes.
        let seconde = Double(base.numer) / Double(base.denom) / 1e9
        var resultat: [pid_t: Double] = [:]
        for pid in pids() {
            if let usage = usage(pid) { resultat[pid] = Double(usage.ri_user_time + usage.ri_system_time) * seconde }
        }
        return resultat
    }

    /// Tous les processus du Mac.
    static func pids() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let nombre = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(0, nombre)).filter { $0 > 0 }
    }

    /// Compteurs d'un processus (nil s'il n'est pas lisible : processus du système).
    static func usage(_ pid: pid_t) -> rusage_info_v2? {
        var usage = rusage_info_v2()
        let retour = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return retour == 0 ? usage : nil
    }

    static func nom(_ pid: pid_t) -> String {
        var tampon = [CChar](repeating: 0, count: 256)
        let longueur = proc_name(pid, &tampon, UInt32(tampon.count))
        guard longueur > 0 else { return "processus \(pid)" }
        let nom = String(decoding: tampon.prefix(Int(longueur)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard !nom.contains(where: \.isLetter) else { return nom }
        var chemin = [CChar](repeating: 0, count: 4096)
        let taille = proc_pidpath(pid, &chemin, UInt32(chemin.count))
        return taille > 0 ? lisible(nom, chemin: String(decoding: chemin.prefix(Int(taille)).map { UInt8(bitPattern: $0) }, as: UTF8.self)) : nom
    }

    /// Un programme rangé sous son numéro de version (« …/node/versions/22.11.0 ») n'a que ce numéro pour nom :
    /// le dossier qui le range est plus parlant.
    static func lisible(_ nom: String, chemin: String) -> String {
        guard !nom.contains(where: \.isLetter) else { return nom }
        let dossiers = chemin.split(separator: "/").dropLast().reversed()
        return dossiers.first { $0.contains(where: \.isLetter) && !["versions", "bin"].contains($0.lowercased()) }.map(String.init) ?? nom
    }

    static func parent(_ pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let taille = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, taille) == taille ? pid_t(info.pbi_ppid) : 0
    }

    /// Fonction du système, absente des en-têtes publics : elle est cherchée à l'exécution, et si elle
    /// disparaît le rattachement se fait par les parents.
    private static let responsableDe: (@convention(c) (pid_t) -> pid_t)? = {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
            .map { unsafeBitCast($0, to: (@convention(c) (pid_t) -> pid_t).self) }
    }()

    static func responsable(_ pid: pid_t) -> pid_t {
        max(0, responsableDe?(pid) ?? 0)
    }
}

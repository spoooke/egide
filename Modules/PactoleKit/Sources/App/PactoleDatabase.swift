import EgideUI
import Foundation
import SwiftData

/// Base de Money (nommée « Money » : chaque module d'Égide a la sienne).
@MainActor
enum PactoleDatabase {
    static let container: ModelContainer = {
        do {
            let schema = Schema(PactoleSchema.models)
            if EgideDemo.actif {
                let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
                ajouterPostesDeDepart(dans: container.mainContext)
                remplirDemo(container.mainContext)
                return container
            }
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration("Money", schema: schema))
            ajouterPostesDeDepart(dans: container.mainContext)
            PactoleSync.shared.attach(container)
            return container
        } catch {
            fatalError("Base de données illisible : \(error)")
        }
    }()

    /// Postes du « Suivi hebdo » manquants et, au premier lancement, règles de classement de départ.
    /// Ne modifie jamais un poste ou une règle existants.
    static func ajouterPostesDeDepart(dans context: ModelContext) {
        // Postes de départ absents (premier lancement, ou poste ajouté par une mise à jour, comme Frais pro).
        // Identifiants fixes : jamais en double entre l'iPhone et le Mac.
        let existants = Set(((try? context.fetch(FetchDescriptor<Poste>())) ?? []).map(\.syncID))
        Poste.depart().filter { !existants.contains($0.syncID) }.forEach(context.insert)
        if (try? context.fetchCount(FetchDescriptor<Regle>())) == 0 {
            Regle.depart().forEach(context.insert)
        }
        try? context.save()
    }
}

/// Réglages propres à l'appareil (préfixe « money. » : les préférences d'Égide sont partagées entre modules).
enum PactoleReglages {
    private static let clePlafondHebdo = "money.plafondHebdoCentimes"
    /// Signet du fichier transactions.csv choisi dans l'app (lecture de secours).
    static let cleSignetCSV = "money.signetTransactionsCSV"

    /// Where Pactole keeps its settings. In demo mode, a separate store filled with made-up values:
    /// the real balance, salary and ceiling are neither shown nor overwritten.
    /// UserDefaults is thread-safe; the store itself never changes after launch.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        let suite = "com.spoooke.egide.demo.pactole"
        guard EgideDemo.actif, let demo = UserDefaults(suiteName: suite) else { return .standard }
        demo.removePersistentDomain(forName: suite)
        let valeurs: [String: Any] = [
            clePlafondHebdo: 135_00, "money.soldeCentimes": 1_240_00, "money.soldeDate": Date.now.timeIntervalSince1970,
            "money.jourPaie": 6, "money.salaireAttenduCentimes": 1_850_00, "money.margeCentimes": 100_00, "money.paieRecue": 0.0,
        ]
        valeurs.forEach { demo.set($1, forKey: $0) }
        return demo
    }()

    static var plafondHebdoCentimes: Int {
        get { PactoleReglages.defaults.object(forKey: clePlafondHebdo) as? Int ?? 135_00 }
        set {
            PactoleReglages.defaults.set(newValue, forKey: clePlafondHebdo)
            plafondHebdoModifie = .now
        }
    }

    /// Date du dernier changement du plafond de la semaine (la plus récente gagne à la synchro).
    static var plafondHebdoModifie: Date {
        get { PactoleReglages.defaults.object(forKey: "money.plafondHebdoModifie") as? Date ?? .distantPast }
        set { PactoleReglages.defaults.set(newValue, forKey: "money.plafondHebdoModifie") }
    }

    /// Date du dernier changement de l'écran « Solde et paie » (le plus récent gagne à la synchro).
    static var tresorerieModifie: Date {
        get { PactoleReglages.defaults.object(forKey: "money.tresorerieModifie") as? Date ?? .distantPast }
        set { PactoleReglages.defaults.set(newValue, forKey: "money.tresorerieModifie") }
    }

    /// Réglages de « Solde et paie » (mêmes clés que les @AppStorage de TresorerieView).
    static var tresorerie: ReglagesTresorerie {
        get {
            let d = PactoleReglages.defaults
            return ReglagesTresorerie(
                soldeCentimes: d.object(forKey: "money.soldeCentimes") as? Int ?? 0,
                soldeDate: d.object(forKey: "money.soldeDate") as? Double ?? 0,
                jourPaie: d.object(forKey: "money.jourPaie") as? Int ?? 6,
                salaireAttenduCentimes: d.object(forKey: "money.salaireAttenduCentimes") as? Int ?? 0,
                margeCentimes: d.object(forKey: "money.margeCentimes") as? Int ?? 100_00,
                paieRecue: d.object(forKey: "money.paieRecue") as? Double ?? 0)
        }
        set {
            let d = PactoleReglages.defaults
            d.set(newValue.soldeCentimes, forKey: "money.soldeCentimes")
            d.set(newValue.soldeDate, forKey: "money.soldeDate")
            d.set(newValue.jourPaie, forKey: "money.jourPaie")
            d.set(newValue.salaireAttenduCentimes, forKey: "money.salaireAttenduCentimes")
            d.set(newValue.margeCentimes, forKey: "money.margeCentimes")
            d.set(newValue.paieRecue, forKey: "money.paieRecue")
        }
    }
}

/// Solde saisi et réglages de la paie, synchronisés entre l'iPhone et le Mac (dates en secondes Unix).
struct ReglagesTresorerie: Codable, Equatable {
    var soldeCentimes: Int
    var soldeDate: Double
    var jourPaie: Int
    var salaireAttenduCentimes: Int
    var margeCentimes: Int
    var paieRecue: Double
}

extension PactoleDatabase {
    /// Mode démo : une semaine et un mois de dépenses inventées (commerçants génériques, aucune donnée réelle).
    static func remplirDemo(_ context: ModelContext) {
        let jour = 86_400.0
        let maintenant = Date.now
        let lignes: [(Int, String, Double, String)] = [
            (23_40, "courses", 0.3, "Supermarché"), (8_50, "restos", 1.2, "Boulangerie"), (12_00, "transport", 1.5, "Parking"),
            (46_80, "courses", 2.4, "Supermarché"), (15_90, "jeux", 3.1, "Boutique en ligne"), (31_20, "restos", 4.0, "Pizzeria"),
            (62_10, "courses", 9.0, "Supermarché"), (18_00, "divers", 11.0, "Pharmacie"), (40_00, "transport", 13.0, "Carburant"),
            (27_50, "restos", 15.0, "Restaurant"), (54_30, "courses", 17.0, "Marché"),
        ]
        for (centimes, poste, jours, note) in lignes {
            context.insert(Depense(montantCentimes: centimes, posteID: poste, date: maintenant.addingTimeInterval(-jours * jour), note: note))
        }
        try? context.save()
    }
}

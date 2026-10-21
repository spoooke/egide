import EgideUI
import Foundation

public extension Historique {
    /// Mode démo d'Égide : quelques audits inventés, de dépôts et d'apps qui n'existent pas.
    static var demo: [AuditGarde] {
        let heure = 3_600.0
        func audit(_ source: String, _ type: Cible.Sorte, _ verdict: Verdict, _ resume: String, ilYa: Double) -> AuditGarde {
            let rapport = Rapport(cible: Cible(type: type, source: source), date: .now.addingTimeInterval(-ilYa * heure), verdict: verdict,
                                  resume: resume, constats: [], reseau: Reseau(), nonAnalyse: [],
                                  couches: Couches(regles: true, ia: true), fichiersAnalyses: 240)
            return AuditGarde(dossier: URL(filePath: "/demo/\(source)"), rapport: rapport)
        }
        return [
            audit("https://github.com/exemple/outil-sauvegarde", .depot, .rienDeGrave, "Aucun comportement suspect.", ilYa: 2),
            audit("ConvertisseurPDF.app", .app, .risque, "Envoie des statistiques d'usage à un serveur tiers.", ilYa: 26),
            audit("https://github.com/exemple/script-installation", .depot, .nePasInstaller,
                  "Télécharge et exécute un script distant avec les droits administrateur.", ilYa: 50),
            audit("pypi:exemple-utilitaires", .depot, .rienDeGrave, "Aucun comportement suspect.", ilYa: 75),
            audit("NotesRapides.dmg", .fichier, .rienDeGrave, "Aucun comportement suspect.", ilYa: 120),
        ]
    }
}

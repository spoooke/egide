import CryptoKit
import Foundation

/// Ce qui change d'un système à l'autre (emplacements, outils, signatures, empreintes) : version Mac.
/// Le moteur commun (`Sources/Commun`) ne passe que par ici ; la version Windows est dans `Sources/Windows`.
public enum Plateforme {
    /// Dossier de travail de Cerbère (quarantaine, journal), hors Bureau et hors iCloud.
    static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Cerbere")
    }

    /// Fichier vide du système, pour couper un réglage de git.
    static let nul = "/dev/null"

    /// Environnement des outils du système : réduit, sans les variables de la session.
    static let environnement = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "HOME": NSTemporaryDirectory()]

    // MARK: - Quarantaine

    /// Rien à préparer sur le Mac : les droits sont posés fichier par fichier (`Quarantaine.verrouiller`).
    static func preparer(racine: URL) throws {}

    /// Un chemin relatif tel que le parcours d'un dossier le donne : déjà avec des « / ».
    static func relatif(_ chemin: String) -> String { chemin }

    /// Un chemin tel qu'un outil du système l'attend : inchangé sur le Mac.
    static func cheminOutil(_ chemin: String) -> String { chemin }

    /// Supprime un dossier de la quarantaine (les dossiers y sont en 0700 : rien à rendre avant).
    static func supprimer(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    static func supprimer(_ url: URL, exiger: Bool) throws { try FileManager.default.removeItem(at: url) }

    /// Le programme qui écrivait un journal n'existe plus (arrêté sans écrire la fin).
    static func processusDisparu(_ pid: Int32) -> Bool { kill(pid, 0) != 0 && errno == ESRCH }

    // MARK: - Outils

    static let git = "/usr/bin/git"

    /// Configuration git de la machine ignorée : pas de filtres, pas de modèle de hooks, pas d'aide aux identifiants.
    static func environnementGit(maison: URL) -> [String: String] {
        ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
         "GIT_ATTR_NOSYSTEM": "1", "GIT_LFS_SKIP_SMUDGE": "1", "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false",
         "PATH": "/usr/bin:/bin", "HOME": maison.path, "LC_ALL": "C"]
    }

    private static let optionsBsdtar = ["--no-same-owner", "--no-same-permissions", "--no-xattrs", "--no-acls", "--no-fflags", "--no-mac-metadata"]

    /// Extraction par bsdtar, sans plafond de taille (archive déjà mesurée).
    static func extraction(_ archive: String, vers cible: String) -> (outil: String, arguments: [String]) {
        ("/usr/bin/bsdtar", ["-x", "-f", archive, "-C", cible] + optionsBsdtar)
    }

    /// Extraction par bsdtar avec un plafond de taille par fichier (`ulimit -f`, en blocs de 512 octets), posé par le
    /// shell ; les chemins sont des arguments, jamais du texte de commande.
    static func extractionBornee(_ archive: String, vers cible: String) -> (outil: String, arguments: [String]) {
        ("/bin/sh", ["-c", #"ulimit -f 1000000; exec /usr/bin/bsdtar -x -f "$1" -C "$2" "# + optionsBsdtar.joined(separator: " "),
                     "sh", archive, cible])
    }

    /// Désassembleur : objdump de LLVM, fourni avec les outils de développement d'Apple.
    static let objdump = "/usr/bin/objdump"
    static let objdumpAbsent = "outils de développement d'Apple absents"

    static func architecturesMachO(_ chemin: String, annulation: Annulation?) -> [String] {
        Outil.lancer("/usr/bin/lipo", ["-archs", chemin], annulation: annulation, delai: 30).sortie.split(separator: " ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// yara installé par Homebrew.
    static let yara = ["/opt/homebrew/bin/yara", "/usr/local/bin/yara"]
    static let installerYara = "brew install yara"

    // MARK: - Lecture par IA

    public static var claude: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/claude") }

    static var environnementIA: [String: String] {
        ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "USER": NSUserName(), "PATH": "/usr/bin:/bin", "LANG": "fr_FR.UTF-8"]
    }

    // MARK: - Empreintes et décompression

    static func sha256(_ donnees: Data) -> String {
        SHA256.hash(data: donnees).map { String(format: "%02x", $0) }.joined()
    }

    /// Flux « deflate » brut (sans l'en-tête zlib), comme dans un PDF.
    static func degonfler(_ flux: Data, max: Int) -> Data? {
        try? (flux as NSData).decompressed(using: .zlib) as Data
    }

    // MARK: - Signatures et conteneurs

    static let noteAuthenticode = "non vérifiée sur un Mac"

    /// Signature d'une app, vérifiée sur l'app elle-même (la copie de quarantaine ne recrée pas ses liens internes).
    static func examinerApp(_ app: URL, gatekeeper: Bool, annulation: Annulation?, dans examen: inout Examen) {
        Signature.examiner(app, nom: app.lastPathComponent, sorte: .app, gatekeeper: gatekeeper, annulation: annulation, dans: &examen)
    }

    /// Apps rangées dans un dossier (archive, image, paquet) : signature de chacune.
    static func examinerApps(dans base: URL, prefixe: String = "", fiable: Bool, gatekeeper: Bool, annulation: Annulation?, dans examen: inout Examen) {
        Signature.examinerApps(dans: base, prefixe: prefixe, fiable: fiable, gatekeeper: gatekeeper, annulation: annulation, dans: &examen)
    }

    /// Programme seul : la signature d'un programme du Mac est lue sur place (Gatekeeper n'a pas d'avis sur un programme seul).
    static func examinerProgramme(_ fichier: URL, format: String, gatekeeper: Bool, annulation: Annulation?, dans examen: inout Examen) {
        guard format == "Mach-O" else { return }
        Signature.examiner(fichier, nom: fichier.lastPathComponent, sorte: .binaire, gatekeeper: false, annulation: annulation, dans: &examen)
    }

    static func ouvrirConteneur(_ fichier: URL, nature: Quarantaine.Nature, nom: String, provisoire: URL, contenu: URL, gatekeeper: Bool,
                                annulation: Annulation?, examen: inout Examen, _ lire: (URL, String) throws -> Void) throws {
        try Quarantaine.ouvrirConteneurMac(fichier, nature: nature, nom: nom, provisoire: provisoire, contenu: contenu, gatekeeper: gatekeeper,
                                           annulation: annulation, examen: &examen, lire)
    }
}

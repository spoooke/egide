import Foundation

/// Lecture d'un programme Windows (format PE) ici même, octet par octet : en-têtes, sections, fonctions importées,
/// signature, données ajoutées en fin de fichier. Le programme n'est jamais lancé.
enum Windows {
    struct Section: Sendable {
        let nom: String
        let adresse: Int, tailleVirtuelle: Int
        let debut: Int, taille: Int
        let executable: Bool
        /// Désordre des octets, de 0 à 8 bits par octet : au-delà de 7,2, contenu compressé ou chiffré.
        let entropie: Double
    }

    struct Programme: Sendable {
        let architecture: String
        let bits64: Bool
        let base: Int
        let sousSysteme: String
        let horodatage: Int
        let sections: [Section]
        /// DLL et fonctions importées (« #12 » pour un import par numéro).
        let imports: [(dll: String, fonctions: [String])]
        /// Adresse d'une case de la table d'import → « dll!fonction ».
        let cases: [Int: String]
        let signe: Bool
        let dotnet: Bool
        /// Octets après la dernière section, signature exclue.
        let surplus: Int

        var fonctions: Set<String> { Set(imports.flatMap(\.fonctions)) }

        /// Position dans le fichier d'une adresse du programme chargé, si elle tombe dans une section.
        func position(_ adresse: Int) -> Int? {
            let rva = adresse - base
            guard let s = sections.first(where: { rva >= $0.adresse && rva < $0.adresse + max($0.tailleVirtuelle, $0.taille) }) else { return nil }
            let p = rva - s.adresse
            return p < s.taille ? s.debut + p : nil
        }
    }

    /// Au-delà, les tables du programme ne sont plus lues (un fichier piégé peut annoncer des tailles absurdes).
    static let importsMax = 4000

    static func lire(_ d: Data) -> Programme? { d.withUnsafeBytes { lire(octets: $0) } }

    /// Lu en place : un gros programme n'est pas recopié en mémoire.
    private static func lire(octets o: UnsafeRawBufferPointer) -> Programme? {
        func u16(_ p: Int) -> Int? { p >= 0 && p + 2 <= o.count ? Int(o[p]) | Int(o[p + 1]) << 8 : nil }
        func u32(_ p: Int) -> Int? { p >= 0 && p + 4 <= o.count ? (0..<4).reduce(0) { $0 | Int(o[p + $1]) << (8 * $1) } : nil }
        func u64(_ p: Int) -> UInt64? { p >= 0 && p + 8 <= o.count ? (0..<8).reduce(UInt64(0)) { $0 | UInt64(o[p + $1]) << (8 * UInt64($1)) } : nil }
        func texte(_ p: Int, max: Int = 256) -> String? {
            guard p >= 0, p < o.count else { return nil }
            var fin = p
            while fin < o.count, fin - p < max, o[fin] != 0 { fin += 1 }
            let s = String(decoding: o[p..<fin], as: UTF8.self)
            return s.isEmpty || s.unicodeScalars.contains { $0.value < 0x20 || $0.value > 0x7E } ? nil : s
        }

        guard o.count > 0x40, o[0] == 0x4D, o[1] == 0x5A, let pe = u32(0x3C), pe < o.count - 24,
              o[pe] == 0x50, o[pe + 1] == 0x45, o[pe + 2] == 0, o[pe + 3] == 0,
              let machine = u16(pe + 4), let nombre = u16(pe + 6), let horodatage = u32(pe + 8), let tailleOptionnel = u16(pe + 20)
        else { return nil }
        let opt = pe + 24
        guard let magie = u16(opt), magie == 0x10B || magie == 0x20B else { return nil }
        let bits64 = magie == 0x20B
        let base = bits64 ? Int(truncatingIfNeeded: u64(opt + 24) ?? 0) : (u32(opt + 28) ?? 0)
        let sousSysteme = u16(opt + 68) ?? 0
        let repertoires = opt + (bits64 ? 112 : 96)
        let nombreRepertoires = min(u32(opt + (bits64 ? 108 : 92)) ?? 0, 16)
        func repertoire(_ i: Int) -> (adresse: Int, taille: Int) {
            guard i < nombreRepertoires, let a = u32(repertoires + 8 * i), let t = u32(repertoires + 8 * i + 4) else { return (0, 0) }
            return (a, t)
        }

        var sections: [Section] = []
        let tableSections = opt + tailleOptionnel
        for i in 0..<min(nombre, 96) {
            let h = tableSections + 40 * i
            guard let vt = u32(h + 8), let va = u32(h + 12), let t = u32(h + 16), let p = u32(h + 20), let car = u32(h + 36) else { break }
            let nom = String(decoding: o[h..<h + 8].prefix { $0 != 0 }, as: UTF8.self)
            let debut = min(p, o.count), taille = min(t, o.count - debut)
            sections.append(Section(nom: nom, adresse: va, tailleVirtuelle: vt, debut: debut, taille: taille,
                                    executable: car & 0x2000_0000 != 0, entropie: entropie(o[debut..<debut + taille])))
        }
        func position(rva: Int) -> Int? {
            guard let s = sections.first(where: { rva >= $0.adresse && rva < $0.adresse + max($0.tailleVirtuelle, $0.taille) }) else {
                // En-têtes : avant la première section, adresse et position se confondent.
                return rva < (sections.map(\.adresse).min() ?? 0) && rva < o.count ? rva : nil
            }
            let p = rva - s.adresse
            return p < s.taille ? s.debut + p : nil
        }

        var imports: [(dll: String, fonctions: [String])] = [], cases: [Int: String] = [:], lus = 0
        let tableImports = repertoire(1)
        if tableImports.adresse != 0, var d = position(rva: tableImports.adresse) {
            while lus < importsMax, let ilt = u32(d), let nomDLL = u32(d + 12), let iat = u32(d + 16), nomDLL != 0 || iat != 0 {
                let dll = position(rva: nomDLL).flatMap { texte($0) } ?? "?"
                var fonctions: [String] = []
                let taille = bits64 ? 8 : 4
                if let table = position(rva: ilt != 0 ? ilt : iat) {
                    var i = 0
                    while lus < importsMax, let v = bits64 ? u64(table + taille * i) : u32(table + taille * i).map(UInt64.init), v != 0 {
                        let parNumero = bits64 ? v & (1 << 63) != 0 : v & (1 << 31) != 0
                        let nom = parNumero ? "#\(v & 0xFFFF)" : (position(rva: Int(v & 0x7FFF_FFFF)).flatMap { texte($0 + 2) } ?? "?")
                        fonctions.append(nom)
                        cases[base + iat + taille * i] = "\(dll)!\(nom)"
                        i += 1
                        lus += 1
                    }
                }
                imports.append((dll, fonctions))
                d += 20
            }
        }

        let signature = repertoire(4)
        let finSections = sections.map { $0.debut + $0.taille }.max() ?? 0
        // La signature (table des certificats) se range d'ordinaire après la dernière section : elle n'est pas un surplus.
        var surplus = max(0, o.count - finSections)
        if signature.adresse >= finSections, signature.taille > 0 { surplus = max(0, surplus - signature.taille) }
        let architectures = [0x14C: "x86 32 bits", 0x8664: "x86-64", 0xAA64: "ARM64", 0x1C4: "ARM", 0xA641: "ARM64EC"]
        let sousSystemes = [1: "pilote ou natif", 2: "fenêtres", 3: "console", 9: "Windows CE", 10: "EFI", 16: "démarrage"]
        return Programme(architecture: architectures[machine] ?? String(format: "machine 0x%X", machine), bits64: bits64, base: base,
                         sousSysteme: sousSystemes[sousSysteme] ?? "\(sousSysteme)", horodatage: horodatage, sections: sections,
                         imports: imports, cases: cases, signe: signature.taille > 0, dotnet: repertoire(14).taille > 0, surplus: surplus)
    }

    static func entropie<C: Collection>(_ octets: C) -> Double where C.Element == UInt8 {
        guard !octets.isEmpty else { return 0 }
        var compte = [Int](repeating: 0, count: 256)
        for b in octets { compte[Int(b)] += 1 }
        let n = Double(octets.count)
        return compte.reduce(0.0) { s, c in c == 0 ? s : s - Double(c) / n * log2(Double(c) / n) }
    }

    /// Textes UTF-16 (ceux des programmes Windows, que `strings` ne lit pas) : au moins `minimum` caractères imprimables.
    static func textesUTF16(_ d: Data, minimum: Int = 6, max: Int = 20_000) -> [String] {
        d.withUnsafeBytes { textesUTF16(octets: $0, minimum: minimum, max: max) }
    }

    private static func textesUTF16(octets o: UnsafeRawBufferPointer, minimum: Int, max: Int) -> [String] {
        var resultats: [String] = []
        for depart in 0..<2 {
            var courant: [UInt16] = []
            var i = depart
            while i + 1 < o.count, resultats.count < max {
                let c = UInt16(o[i]) | UInt16(o[i + 1]) << 8
                if (0x20...0x7E).contains(c) || c == 0x09 || (0xC0...0x17F).contains(c) { courant.append(c) } else {
                    if courant.count >= minimum { resultats.append(String(decoding: courant, as: UTF16.self)) }
                    courant.removeAll(keepingCapacity: true)
                }
                i += 2
            }
            if courant.count >= minimum { resultats.append(String(decoding: courant, as: UTF16.self)) }
        }
        return resultats
    }

    // MARK: Fonctions importées

    /// Familles de fonctions Windows. Motif : nom exact, ou préfixe s'il finit par `*` (les variantes A et W).
    static let familles: [(nom: String, motifs: [String])] = [
        ("réseau", ["WSAStartup", "socket", "connect", "send", "recv", "InternetOpen*", "InternetConnect*", "InternetOpenUrl*", "InternetReadFile",
                    "HttpOpenRequest*", "HttpSendRequest*", "WinHttp*", "URLDownloadToFile*", "URLOpenStream*", "DnsQuery*"]),
        ("lancement de commandes", ["WinExec", "ShellExecute*", "CreateProcess*", "system", "_wsystem", "_popen", "_wpopen"]),
        ("chargement de code", ["LoadLibrary*", "GetProcAddress", "LdrLoadDll", "VirtualAlloc", "VirtualProtect", "NtAllocateVirtualMemory"]),
        ("action sur d'autres programmes", ["OpenProcess", "VirtualAllocEx", "VirtualProtectEx", "WriteProcessMemory", "ReadProcessMemory", "CreateRemoteThread*",
                                            "NtCreateThreadEx", "QueueUserAPC", "SetThreadContext", "NtUnmapViewOfSection", "ZwUnmapViewOfSection", "ResumeThread"]),
        ("clavier, écran, presse-papiers", ["SetWindowsHookEx*", "GetAsyncKeyState", "GetKeyState", "GetKeyboardState", "BitBlt", "GetClipboardData", "RegisterRawInputDevices"]),
        ("mots de passe enregistrés", ["CryptUnprotectData", "CredEnumerate*", "CredRead*", "LsaRetrievePrivateData"]),
        ("registre et services", ["RegSetValueEx*", "RegCreateKey*", "CreateService*", "OpenSCManager*", "ChangeServiceConfig*"]),
        ("droits d'administrateur", ["AdjustTokenPrivileges", "LookupPrivilegeValue*", "ImpersonateLoggedOnUser", "DuplicateTokenEx"]),
        ("chiffrement", ["CryptEncrypt", "CryptAcquireContext*", "BCryptEncrypt", "CryptGenKey"]),
        ("anti-analyse", ["IsDebuggerPresent", "CheckRemoteDebuggerPresent", "NtQueryInformationProcess", "OutputDebugString*"]),
    ]

    static func correspond(_ fonction: String, _ motif: String) -> Bool {
        motif.hasSuffix("*") ? fonction.hasPrefix(motif.dropLast()) : fonction == motif
    }

    static func famille(de fonction: String) -> String? {
        familles.first { $0.motifs.contains { correspond(fonction, $0) } }?.nom
    }

    struct Alerte {
        let regle: String
        /// Il faut au moins une fonction de chaque groupe.
        let groupes: [[String]]
        let gravite: Gravite
        let categorie: Categorie
        let titre: String
        let explication: String
    }

    static let alertes: [Alerte] = [
        Alerte(regle: "win.injection", groupes: [["VirtualAllocEx", "NtAllocateVirtualMemory"], ["WriteProcessMemory"], ["CreateRemoteThread*", "NtCreateThreadEx", "QueueUserAPC", "SetThreadContext"]],
               gravite: .elevee, categorie: .obfuscation, titre: "Peut injecter du code dans un autre programme",
               explication: "Réserver de la mémoire dans un autre programme, y écrire, puis y lancer un fil : procédé typique d'un malware qui se cache dans un programme sain."),
        Alerte(regle: "win.creusement", groupes: [["NtUnmapViewOfSection", "ZwUnmapViewOfSection"], ["WriteProcessMemory"], ["SetThreadContext", "ResumeThread"]],
               gravite: .elevee, categorie: .obfuscation, titre: "Peut remplacer le contenu d'un autre programme",
               explication: "Vider un programme lancé puis y écrire un autre code : le malware se fait passer pour un programme connu."),
        Alerte(regle: "win.telecharge-execute", groupes: [["URLDownloadToFile*", "InternetOpenUrl*", "InternetReadFile", "WinHttp*"], ["WinExec", "ShellExecute*", "CreateProcess*"]],
               gravite: .moyenne, categorie: .reseau, titre: "Peut télécharger puis lancer un programme",
               explication: "Le programme importe de quoi télécharger et de quoi lancer : normal pour un installateur ou une mise à jour, c'est aussi ainsi qu'arrive une charge malveillante."),
        Alerte(regle: "win.clavier", groupes: [["SetWindowsHookEx*", "GetAsyncKeyState", "RegisterRawInputDevices"]],
               gravite: .moyenne, categorie: .secrets, titre: "Peut suivre ce qui est tapé au clavier",
               explication: "Ces fonctions observent le clavier hors de la fenêtre du programme : normal pour un outil de raccourcis, anormal ailleurs."),
        Alerte(regle: "win.mots-de-passe", groupes: [["CryptUnprotectData", "CredEnumerate*", "LsaRetrievePrivateData"]],
               gravite: .moyenne, categorie: .secrets, titre: "Peut lire des mots de passe enregistrés",
               explication: "Ces fonctions déchiffrent les secrets rangés par Windows ou par les navigateurs : ce que cherchent les voleurs de mots de passe."),
        Alerte(regle: "win.anti-analyse", groupes: [["IsDebuggerPresent", "CheckRemoteDebuggerPresent"]],
               gravite: .faible, categorie: .obfuscation, titre: "Vérifie s'il est observé",
               explication: "Le programme regarde si un débogueur le suit. Courant dans les logiciels protégés contre la copie, et dans les malwares."),
    ]

    /// Sections nommées par les outils qui compressent ou chiffrent un programme.
    static let empaqueteurs: [String: String] = ["UPX0": "UPX", "UPX1": "UPX", "UPX2": "UPX", ".aspack": "ASPack", ".adata": "ASPack", ".MPRESS1": "MPRESS",
                                                 ".MPRESS2": "MPRESS", ".petite": "Petite", ".nsp0": "NsPack", ".nsp1": "NsPack", ".themida": "Themida",
                                                 ".vmp0": "VMProtect", ".vmp1": "VMProtect", ".enigma1": "Enigma", "PEC2": "PECompact"]

    /// Fiche `[imports]` d'un programme Windows, et ses constats.
    static func examiner(_ p: Programme, chemin: String, taille: Int) -> Examen {
        var examen = Examen()
        let fiche = "\(chemin) [imports]"
        var lignes = ["Fiche produite par Cerbère, en lecture seule : le programme Windows n'a pas été lancé. Elle dit ce qu'il peut appeler, pas ce qu'il fait."]
        func constat(_ regle: String, _ gravite: Gravite, _ statut: Statut, _ categorie: Categorie, _ titre: String, _ explication: String) {
            examen.constats.append(Constat(id: "", gravite: gravite, statut: statut, categorie: categorie, titre: titre, fichier: fiche, lignes: [lignes.count, lignes.count],
                                           extrait: String(lignes[lignes.count - 1].trimmingCharacters(in: .whitespaces).prefix(300)), explication: explication, origine: .regle, regle: regle))
        }
        let date = Date(timeIntervalSince1970: TimeInterval(p.horodatage))
        lignes.append("Programme Windows \(p.bits64 ? "64" : "32") bits (\(p.architecture)), \(p.sousSysteme), compilé le \(date.formatted(.iso8601.year().month().day())) d'après son en-tête (date modifiable)")
        lignes.append(p.signe ? "Signature Authenticode : présente (\(Plateforme.noteAuthenticode))" : "Signature Authenticode : absente")
        if !p.signe {
            constat("win.sans-signature", .faible, .confirme, .autre, "Programme Windows sans signature",
                    "Personne ne garantit son origine. Courant pour un petit outil libre ; un logiciel du commerce est d'ordinaire signé.")
        }
        if p.dotnet {
            lignes.append("Programme .NET : son code (langage intermédiaire) n'est pas désassemblé par Cerbère")
            examen.nonAnalyse.append(NonAnalyse(fichier: chemin, raison: "programme .NET : code intermédiaire non désassemblé"))
        }
        lignes.append("Sections (\(p.sections.count)) :")
        for s in p.sections {
            lignes.append(String(format: "  %@ : %d octets, %@entropie %.1f sur 8", s.nom, s.taille, s.executable ? "code, " : "", s.entropie))
        }
        let nomsEmpaqueteurs = Set(p.sections.compactMap { empaqueteurs[$0.nom] })
        let desordonnees = p.sections.filter { $0.entropie > 7.2 && $0.taille >= 1024 }
        if !nomsEmpaqueteurs.isEmpty || !desordonnees.isEmpty {
            let qui = nomsEmpaqueteurs.isEmpty ? "" : " par \(nomsEmpaqueteurs.sorted().joined(separator: ", "))"
            lignes.append("Code compressé ou chiffré\(qui) : " + (desordonnees.isEmpty ? p.sections.filter { empaqueteurs[$0.nom] != nil }.map(\.nom) : desordonnees.map(\.nom)).joined(separator: ", "))
            constat("win.empaquete", .moyenne, .suspect, .obfuscation, "Programme compressé ou chiffré",
                    "Son vrai code n'apparaît qu'une fois lancé : ni ses fonctions ni ses textes ne sont lisibles ici. Procédé courant des malwares, mais aussi de logiciels qui se protègent de la copie.")
            examen.nonAnalyse.append(NonAnalyse(fichier: chemin, raison: "programme compressé ou chiffré : son vrai code n'est pas lisible sans le lancer"))
        }
        if p.surplus > 0 {
            lignes.append("Données ajoutées après la dernière section : \(p.surplus) octets (\(Int((Double(p.surplus) / Double(max(taille, 1)) * 100).rounded())) % du fichier)")
            if p.surplus >= 64 * 1024 {
                constat("win.surplus", .info, .confirme, .autre, "Données cachées en fin de programme",
                        "Un installateur y range souvent ses fichiers ; un malware peut y cacher une charge. Ces données ne sont pas lues par Windows au lancement, seulement par le programme lui-même.")
            }
        }
        let fonctions = p.fonctions
        lignes.append("Bibliothèques (DLL) et fonctions importées (\(fonctions.count)) :")
        for (dll, liste) in p.imports.prefix(200) {
            lignes.append("  \(dll) : " + liste.prefix(400).joined(separator: " "))
        }
        var presentes: [String] = []
        for (nom, motifs) in familles {
            let trouvees = fonctions.filter { f in motifs.contains { correspond(f, $0) } }.sorted()
            guard !trouvees.isEmpty else { continue }
            presentes.append(nom)
            lignes.append("  \(nom) : " + trouvees.prefix(40).joined(separator: ", "))
        }
        for a in alertes where a.groupes.allSatisfy({ g in fonctions.contains { f in g.contains { correspond(f, $0) } } }) {
            let cites = a.groupes.flatMap { g in fonctions.filter { f in g.contains { correspond(f, $0) } } }.sorted()
            lignes.append("  \(a.titre.lowercased()) : " + cites.joined(separator: ", "))
            constat(a.regle, a.gravite, .suspect, a.categorie, a.titre, a.explication)
        }
        lignes.append("Ce que le programme peut faire, d'après ses fonctions importées : " + (presentes.isEmpty ? "rien de notable" : presentes.joined(separator: ", ")))
        constat("bin.capacites", .info, .confirme, .autre, "Ce que le programme peut appeler",
                "Liste tirée des fonctions importées. C'est une capacité, pas une preuve d'usage ; un programme peut aussi cacher ses appels.")
        examen.fiches.append(.fiche(fiche, lignes))
        return examen
    }
}

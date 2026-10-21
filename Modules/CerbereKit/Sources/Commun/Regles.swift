import Foundation

/// Une règle de la couche 1 : un motif cherché dans les fichiers texte.
/// Une règle ne « confirme » que ce qui se lit sans ambiguïté sur la ligne ; le reste est « suspect ».
struct Regle: @unchecked Sendable {
    let id: String
    let categorie: Categorie
    let gravite: Gravite
    let statut: Statut
    let titre: String
    let explication: String
    let motif: NSRegularExpression
    /// Limite la règle à certains noms de fichiers (en minuscules).
    var noms: Set<String>? = nil
    /// Dans la documentation, le constat baisse d'un cran et devient « suspect » ; sauf si `false`.
    var attenueeDansLaDoc = true
    /// Écarte une occurrence d'après le texte trouvé.
    var garde: (@Sendable (String) -> Bool)? = nil

    init(_ id: String, _ categorie: Categorie, _ gravite: Gravite, _ statut: Statut, _ titre: String, _ explication: String,
         _ motif: String, casse: Bool = false, noms: Set<String>? = nil, attenueeDansLaDoc: Bool = true,
         garde: (@Sendable (String) -> Bool)? = nil) {
        self.id = id
        self.categorie = categorie
        self.gravite = gravite
        self.statut = statut
        self.titre = titre
        self.explication = explication
        // Un motif invalide est une faute de programmation : les essais chargent toutes les règles.
        self.motif = try! NSRegularExpression(pattern: motif, options: casse ? [] : [.caseInsensitive])
        self.noms = noms
        self.attenueeDansLaDoc = attenueeDansLaDoc
        self.garde = garde
    }
}

/// Texte d'un fichier avec le repérage des lignes, pour chercher une fois par règle et non une fois par ligne.
struct Texte: @unchecked Sendable {
    let fichier: Fichier
    let contenu: NSString
    /// Position (UTF-16) du début de chaque ligne.
    let debuts: [Int]

    init(_ fichier: Fichier) {
        self.fichier = fichier
        var debuts: [Int] = [], position = 0
        debuts.reserveCapacity(fichier.lignes.count)
        for ligne in fichier.lignes {
            debuts.append(position)
            position += ligne.utf16.count + 1
        }
        self.debuts = debuts
        contenu = fichier.lignes.joined(separator: "\n") as NSString
    }

    /// Numéro de ligne (à partir de 1) d'une position.
    func ligne(_ position: Int) -> Int {
        var bas = 0, haut = debuts.count - 1
        while bas < haut {
            let milieu = (bas + haut + 1) / 2
            if debuts[milieu] <= position { bas = milieu } else { haut = milieu - 1 }
        }
        return bas + 1
    }

    /// La ligne citée, raccourcie autour de l'occurrence.
    func extrait(_ plage: NSRange, largeur: Int = 240) -> String {
        let numero = ligne(plage.location)
        let ligne = fichier.lignes[numero - 1] as NSString
        guard ligne.length > largeur else { return (ligne as String).trimmingCharacters(in: .whitespaces) }
        let dans = plage.location - debuts[numero - 1]
        let debut = max(0, min(dans - largeur / 4, ligne.length - largeur))
        let morceau = ligne.substring(with: ligne.rangeOfComposedCharacterSequences(for: NSRange(location: debut, length: largeur)))
        return (debut > 0 ? "…" : "") + morceau + (debut + largeur < ligne.length ? "…" : "")
    }
}

enum Moteur {
    /// Occurrences gardées par règle et par fichier ; les suivantes sont seulement comptées.
    static let occurrencesMax = 3

    static func appliquer(_ regles: [Regle], a texte: Texte) -> [Constat] {
        let f = texte.fichier
        var constats: [Constat] = []
        for regle in regles {
            if let noms = regle.noms, !noms.contains(f.nom.lowercased()) { continue }
            var gardes: [NSRange] = [], total = 0, derniere = 0
            regle.motif.enumerateMatches(in: texte.contenu as String, range: NSRange(location: 0, length: texte.contenu.length)) { resultat, _, _ in
                guard let plage = resultat?.range, plage.length > 0 else { return }
                if let garde = regle.garde, !garde(texte.contenu.substring(with: plage)) { return }
                let ligne = texte.ligne(plage.location)
                guard ligne != derniere else { return }   // une occurrence par ligne
                derniere = ligne
                total += 1
                if gardes.count < occurrencesMax { gardes.append(plage) }
            }
            let doc = f.estDocumentation && regle.attenueeDansLaDoc
            // « Confirmé » seulement là où la ligne est une commande : dans un autre langage, le même texte
            // peut n'être qu'une chaîne (un essai, un message).
            let statut: Statut = doc || !f.estScript ? .suspect : regle.statut
            for (i, plage) in gardes.enumerated() {
                var explication = regle.explication
                if doc { explication += " Trouvé dans de la documentation : peut n'être qu'une mention ou une consigne d'installation." }
                if i == gardes.count - 1, total > gardes.count { explication += " (+\(total - gardes.count) autres occurrences dans ce fichier.)" }
                let ligne = texte.ligne(plage.location)
                constats.append(Constat(
                    id: "", gravite: doc ? regle.gravite.attenuee : regle.gravite, statut: statut,
                    categorie: regle.categorie, titre: regle.titre, fichier: f.chemin, lignes: [ligne, ligne],
                    extrait: texte.extrait(plage), explication: explication, origine: .regle, regle: regle.id))
            }
        }
        return constats
    }
}

extension Regle {
    /// Adresses locales ou privées : pas un signe d'envoi vers l'extérieur.
    static func adressePublique(_ url: String) -> Bool {
        guard let debut = url.range(of: "://") else { return true }
        let octets = url[debut.upperBound...].split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (0, _), (192, 168), (169, 254): return false
        case (172, 16...31): return false
        default: return true
        }
    }

    static let toutes: [Regle] = reseau + obfuscation + secrets + persistance + manipulation + installation + documents

    // MARK: Réseau

    static let reseau: [Regle] = [
        Regle("reseau.shell-inverse", .reseau, .critique, .confirme, "Shell inversé",
              "Cette commande ouvre un accès à distance à la machine : quelqu'un d'autre peut y taper des commandes.",
              #"/dev/tcp/[^\s/]+/\d+|\bnc(at)?\b[^\n|]{0,40}\s-[a-z]*e\s+\S*(sh|cmd)\b|\bbash\s+-i\s*>&|\bmkfifo\b[^\n]*\|\s*nc\b|socket\.socket\([^\n]*\bdup2\(|pty\.spawn\(\s*["']/bin/(ba)?sh"#),
        Regle("reseau.webhook", .reseau, .elevee, .suspect, "Envoi vers un webhook de messagerie",
              "Les webhooks Discord, Telegram ou Slack servent souvent à faire sortir des données volées.",
              #"discord(app)?\.com/api/webhooks/|api\.telegram\.org/bot|hooks\.slack\.com/services/"#),
        Regle("reseau.env", .reseau, .elevee, .suspect, "Variables d'environnement envoyées",
              "Les variables d'environnement contiennent souvent des clés et des jetons ; ici elles sont jointes à un envoi.",
              #"JSON\.stringify\(\s*process\.env\s*\)|(requests|httpx|session)\.(post|put)\([^\n]*os\.environ\b(?!\s*(\[|\.get))|urlopen\([^\n]*os\.environ\b(?!\s*(\[|\.get))|\bcurl\b[^\n]*(-d|--data[a-z-]*|-F)\s[^\n]*\$\(\s*(env|printenv)\b"#),
        Regle("reseau.depot-anonyme", .reseau, .moyenne, .suspect, "Service de dépôt anonyme ou de tunnel",
              "Ces services reçoivent ou relaient des données sans laisser de trace d'identité.",
              #"\b(pastebin\.com|paste\.ee|hastebin\.com|transfer\.sh|file\.io|anonfiles\.com|0x0\.st|ngrok\.(io|app)|ngrok-free\.app|trycloudflare\.com|serveo\.net|requestbin\.[a-z]+|webhook\.site|pipedream\.net|interact\.sh|oast\.(fun|pro|live|site|me)|burpcollaborator\.net)\b"#),
        Regle("reseau.ip", .reseau, .moyenne, .suspect, "Adresse IP écrite en dur",
              "Le code contacte une adresse IP publique plutôt qu'un nom de domaine.",
              #"\b(https?|wss?|ftp|tcp)://\d{1,3}(\.\d{1,3}){3}(?![\d.])"#, garde: adressePublique),
        Regle("reseau.onion", .reseau, .moyenne, .suspect, "Adresse du réseau Tor",
              "Le code cite un service caché du réseau Tor.", #"\b[a-z2-7]{16,56}\.onion\b"#),
        Regle("reseau.raccourci", .reseau, .faible, .suspect, "Lien raccourci",
              "Un lien raccourci cache sa vraie destination.",
              #"https?://(bit\.ly|tinyurl\.com|t\.co|is\.gd|cutt\.ly|rb\.gy|goo\.gl|shorturl\.at)/\S+"#),
    ]

    // MARK: Code caché ou téléchargé

    static let obfuscation: [Regle] = [
        Regle("obf.telecharge-execute", .obfuscation, .elevee, .confirme, "Code téléchargé et exécuté aussitôt",
              "Ce qui est téléchargé est lancé sans être enregistré ni relu : son contenu peut changer à tout moment.",
              #"\b(curl|wget)\b[^\n|;&]*\|\s*(sudo\s+)?((ba|z|da|k|fi)?sh|python3?|perl|ruby|node|osascript)\b|\b(ba|z)?sh\s+-c\s+["']?\$\(\s*(curl|wget)\b|\b(ba|z)?sh\s+<\(\s*(curl|wget)\b|\b(iex|invoke-expression)\b[^\n]{0,40}(net\.webclient|\biwr\b|invoke-webrequest|\birm\b|invoke-restmethod|downloadstring)"#),
        Regle("obf.decode-execute", .obfuscation, .elevee, .suspect, "Code décodé puis exécuté",
              "Le code lancé est caché sous une forme encodée : on ne peut pas le lire tel quel.",
              #"\b(eval|exec|Function)\s*\(\s*(atob|unescape)\s*\(|\b(eval|exec)\s*\(\s*(base64\.b64decode|codecs\.decode|bytes\.fromhex|zlib\.decompress|marshal\.loads|binascii\.(unhexlify|a2b_base64)|compile\s*\(\s*(base64|zlib|codecs))|\beval\s*\(\s*Buffer\.from\s*\(|new\s+Function\s*\(\s*(atob|Buffer\.from)\s*\(|\beval\s*\(\s*(base64_decode|gzinflate|str_rot13|gzuncompress)\s*\(|\bbase64\s+(-d|--decode|-D)\b[^\n|]*\|\s*(sudo\s+)?((ba|z)?sh|python3?)\b"#),
        Regle("obf.powershell", .obfuscation, .elevee, .suspect, "Commande PowerShell encodée ou cachée",
              "La commande est encodée ou lancée dans une fenêtre invisible.",
              #"powershell(\.exe)?\s[^\n]*\s-(e|enc|encodedcommand)\s+[A-Za-z0-9+/=]{20,}|powershell(\.exe)?\s[^\n]*-w(indowstyle)?\s+hidden"#),
        Regle("obf.execution-dynamique", .obfuscation, .moyenne, .suspect, "Exécution dynamique de code",
              "Du code est fabriqué ou récupéré pendant l'exécution, puis lancé.",
              #"__import__\(\s*['"](os|subprocess|socket|base64|ctypes)['"]\s*\)\.|getattr\(\s*__builtins__|\bexec\s*\(\s*(requests|urllib[\w.]*|httpx)\.[^\n]*\)\s*\.\s*(text|read|content)|\beval\s*\(\s*(await\s+)?\(?\s*(await\s+)?fetch\(|\bexec\s*\(\s*(bytes|bytearray)\(|\bos\.system\(\s*(base64|bytes|codecs)\."#),
        Regle("obf.caracteres", .obfuscation, .moyenne, .suspect, "Texte reconstruit caractère par caractère",
              "Une chaîne est assemblée octet par octet, ce qui la cache à la lecture et aux recherches.",
              #"String\.fromCharCode\((\s*(0x)?[0-9a-f]+\s*,){15,}|(\\x[0-9a-f]{2}){24,}|(\\u00[0-9a-f]{2}){24,}|(chr\(\s*\d+\s*\)\s*[.+]\s*){10,}"#),
        Regle("obf.obfuscateur", .obfuscation, .moyenne, .suspect, "Code passé par un obfuscateur",
              "Les noms de la forme _0x… sont la marque d'un outil qui rend le code illisible exprès.",
              #"\b_0x[0-9a-f]{4,6}\b[^\n]*\b_0x[0-9a-f]{4,6}\b"#),
        Regle("obf.sens-ecriture", .obfuscation, .elevee, .suspect, "Caractères invisibles de sens d'écriture",
              "Ces caractères font afficher le code dans un autre ordre que celui lu par la machine (« Trojan Source »).",
              "[\u{202A}-\u{202E}\u{2066}-\u{2069}]", attenueeDansLaDoc: false),
        Regle("obf.invisible", .obfuscation, .faible, .suspect, "Caractères invisibles",
              "Des caractères de largeur nulle sont glissés dans le texte : ils peuvent cacher des différences ou des données.",
              "[\u{200B}\u{200C}\u{2060}]{2,}|[A-Za-z0-9][\u{200B}\u{200C}\u{2060}][A-Za-z0-9]"),
    ]

    // MARK: Accès aux secrets

    static let secrets: [Regle] = [
        Regle("sec.trousseau", .secrets, .elevee, .suspect, "Lecture du trousseau",
              "Le trousseau garde les mots de passe du Mac ; ce code le lit ou l'exporte en ligne de commande.",
              #"\bsecurity\s+(find-(generic|internet)-password|dump-keychain|unlock-keychain|export)\b|login\.keychain(-db)?\b|Library/Keychains"#),
        Regle("sec.trousseau-api", .secrets, .info, .suspect, "Usage de l'API du trousseau",
              "Courant dans une app qui range ses propres identifiants ; à vérifier : lit-elle seulement les siens ?",
              #"\bSecItemCopyMatching\b|\brequire\(\s*['"]keytar['"]\s*\)|\bkeyring\.get_password\b"#, casse: true),
        Regle("sec.navigateur", .secrets, .elevee, .suspect, "Données de navigateur (mots de passe, cookies)",
              "Ces fichiers contiennent les mots de passe enregistrés et les sessions ouvertes des navigateurs.",
              #"(Google[/\\]+Chrome|BraveSoftware|Microsoft[/\\]+Edge|Chromium|Vivaldi|Opera Software)[^\n]{0,120}(Login Data|Cookies|Local State|Web Data)|Cookies\.binarycookies|\b(logins\.json|key[34]\.db|cookies\.sqlite)\b|Firefox[/\\]+Profiles|Chrome Safe Storage|\bos_crypt\b"#),
        Regle("sec.portefeuille", .secrets, .elevee, .suspect, "Portefeuille de cryptomonnaie",
              "Le code vise les fichiers ou la phrase secrète d'un portefeuille.",
              #"\bwallet\.dat\b|nkbihfbeogaeaoehlefnkodbefgpgknn|bfnaelmomeimhlpmgjnjophhpkkoljpa|(Application Support|AppData[^\n]{0,20})[/\\]+(Exodus|Electrum|atomic|Ledger Live|Bitcoin|Ethereum)\b|\.config/solana/id\.json|\b(seed|recovery)[ _-]?phrase\b"#),
        Regle("sec.cles", .secrets, .elevee, .suspect, "Clés SSH ou GPG",
              "Le code lit le dossier des clés privées de l'utilisateur.",
              #"(~|\$HOME|\$\{HOME\}|Path\.home\(\)|homedir\(\)|expanduser\([^\n)]*\)?)[^\n]{0,40}\.ssh\b|\.ssh/(id_(rsa|ed25519|ecdsa|dsa)|authorized_keys|known_hosts)\b|(~|\$HOME)/\.gnupg\b"#),
        Regle("sec.identifiants", .secrets, .elevee, .suspect, "Fichiers d'identifiants",
              "Ces fichiers contiennent des jetons d'accès (cloud, registres de paquets, git).",
              #"\.aws/credentials|\.config/gcloud\b|\.kube/config\b|\.docker/config\.json|\.git-credentials\b|(~|\$HOME|homedir\(\)[^\n]{0,10})/?\.(npmrc|netrc|pypirc)\b|/etc/shadow\b"#),
        Regle("sec.fausse-demande", .secrets, .elevee, .suspect, "Fausse demande de mot de passe",
              "Une boîte de dialogue fabriquée demande un mot de passe en masquant la saisie : procédé classique des voleurs de mots de passe sur Mac.",
              #"display dialog[^\n]*hidden answer|with hidden answer"#),
        Regle("sec.clavier", .secrets, .elevee, .suspect, "Capture des frappes du clavier",
              "Le code écoute le clavier en dehors de sa propre fenêtre.",
              #"\bfrom\s+pynput\b|\bimport\s+pynput\b|\bkeyboard\.on_press\b|\bCGEventTapCreate\b|addGlobalMonitorForEvents|SetWindowsHookEx|GetAsyncKeyState|\bkeylogg?(er|ing)?\b"#),
        Regle("sec.ecran", .secrets, .moyenne, .suspect, "Capture d'écran silencieuse",
              "Le code prend des captures d'écran sans interface visible.",
              #"\bscreencapture\s+-[a-z]*x|\bCGWindowListCreateImage\b|\bImageGrab\.grab\(|\bCGDisplayCreateImage\b"#),
        Regle("sec.presse-papiers", .secrets, .faible, .suspect, "Lecture du presse-papiers",
              "Le presse-papiers contient souvent des mots de passe ou des adresses de portefeuille.",
              #"\bpbpaste\b|clipboard\.readText\(|pyperclip\.paste\(|\bGet-Clipboard\b|NSPasteboard\.general\.string\(forType"#),
    ]

    // MARK: Persistance

    static let persistance: [Regle] = [
        Regle("per.launchd", .persistance, .elevee, .suspect, "Agent de lancement (démarrage automatique)",
              "Le programme s'installe pour être relancé à chaque ouverture de session ou démarrage du Mac.",
              #"Library/Launch(Agents|Daemons)\b|\blaunchctl\s+(load|bootstrap|enable|submit)\b"#),
        Regle("per.shell", .persistance, .elevee, .suspect, "Modification du démarrage du shell",
              "Une ligne ajoutée à ces fichiers est exécutée à chaque ouverture d'un terminal.",
              #">>?\s*["']?(~|\$HOME|\$\{HOME\})/\.(zshrc|bashrc|bash_profile|zprofile|profile|zshenv|zlogin)\b|\b(open|write|append|writeFile|appendFile)\w*\([^\n]{0,80}\.(zshrc|bashrc|bash_profile|zprofile|zshenv)\b"#),
        Regle("per.ssh", .persistance, .elevee, .suspect, "Clé ajoutée aux accès SSH",
              "Ajouter une clé à authorized_keys donne un accès permanent à la machine.",
              #">>\s*[^\n]*\.ssh/authorized_keys"#),
        Regle("per.planifie", .persistance, .moyenne, .suspect, "Tâche planifiée",
              "Le programme se fait relancer à intervalles réguliers.",
              #"\bcrontab\s+(-[a-z]*\s+)?[^\s-]|\|\s*crontab\b|/etc/cron\.|/var/spool/cron|\bschtasks(\.exe)?\s+/create|\bNew-ScheduledTask|Register-ScheduledTask"#),
        Regle("per.linux", .persistance, .moyenne, .suspect, "Démarrage automatique (Linux)",
              "Le programme s'inscrit comme service ou au démarrage de la session.",
              #"\bsystemctl\s+(--user\s+)?enable\b|/etc/systemd/system/|\.config/systemd/user/|\.config/autostart/|/etc/rc\.local\b|/etc/init\.d/|/etc/profile\.d/"#),
        Regle("per.windows", .persistance, .moyenne, .suspect, "Démarrage automatique (Windows)",
              "Le programme s'inscrit dans les clés de démarrage de Windows.",
              #"CurrentVersion\\+Run(Once)?\b|Start Menu\\+Programs\\+Startup"#),
        Regle("per.connexion", .persistance, .faible, .suspect, "Élément de connexion",
              "L'app demande à s'ouvrir à chaque session ; courant et légitime, à condition que ce soit annoncé.",
              #"\bSMAppService\b|\bSMLoginItemSetEnabled\b|make\s+(new\s+)?login item|com\.apple\.loginitems"#),
        Regle("per.protections", .autre, .elevee, .suspect, "Protections du système affaiblies",
              "Cette commande retire un contrôle de sécurité (quarantaine, Gatekeeper, droits d'administrateur).",
              #"\bxattr\s+-[a-z]*[dc][a-z]*\s+(com\.apple\.quarantine|[^\n]*\.app\b)|\bspctl\s+--(master-disable|global-disable)|\bcsrutil\s+disable|\btccutil\s+reset\b|>>?\s*/etc/sudoers|NOPASSWD\s*:|Set-MpPreference\s+-Disable|\bsetenforce\s+0\b|\bchmod\s+([ug]+\+s|[267][0-7]{3})\b"#),
    ]

    // MARK: Tentative de manipulation

    /// Texte qui s'adresse à l'auditeur ou à l'IA qui lit le dépôt. Jamais atténué : c'est justement
    /// dans la documentation et les commentaires qu'il se cache.
    static let manipulation: [Regle] = [
        Regle("man.instructions", .manipulation, .elevee, .suspect, "Instructions adressées à l'auditeur ou à l'IA",
              "Ce texte cherche à dicter la conclusion de l'audit. Il est signalé comme tentative de manipulation et n'est suivi en aucun cas.",
              #"\bignore\s+(all\s+|any\s+)?(the\s+|your\s+)?(previous|prior|above|earlier)\s+(instructions?|prompts?|rules|context)|\bdisregard\s+(all\s+|any\s+)?(the\s+|your\s+)?(previous|prior|above)\b|ignore[zr]?\s+(toutes\s+)?les\s+(instructions|consignes)\s+(précédentes|ci-dessus)|\b(do\s+not|don't|never)\s+(report|flag|mention|disclose)\s+(this|these|any|the)\b|\b(mark|report|classify|treat|rate)\s+(this|the)\s+(repo(sitory)?|code|file|package|project)\s+as\s+(safe|benign|clean|trusted|harmless)|\bne\s+(signale[zr]?|mentionne[zr]?)\s+pas\b|\bthis\s+(code|file|repo(sitory)?|package)\s+(is|has\s+been)\s+(already\s+)?(audited|verified|reviewed)\s+(and\s+)?(is\s+)?(found\s+)?safe|\b(note|attention|message)\s+(to|for|à\s+l')\s*(the\s+)?(ai|llm|auditor|auditeur|ia|reviewer|scanner)\b"#,
              attenueeDansLaDoc: false),
        Regle("man.role", .manipulation, .faible, .suspect, "Consigne adressée à une IA",
              "Texte du type « tu es une IA, tu dois… ». Normal dans une app qui utilise une IA ; à lire si le dépôt n'en est pas une.",
              #"\b(you\s+are|you're)\s+an?\s+(ai|llm|language\s+model|code\s+review(er)?|security\s+(auditor|scanner))\b[^\n]{0,120}\b(must|should|always|never|do\s+not|don't)\b"#,
              attenueeDansLaDoc: false),
    ]

    // MARK: Documents (le reste est dans Documents.swift)

    static let documents: [Regle] = [
        Regle("doc.modele-distant", .obfuscation, .elevee, .suspect, "Document qui charge un modèle ou un objet distant",
              "À l'ouverture, le document va chercher un modèle ou un objet sur un serveur : c'est par là qu'arrivent les macros d'un document « propre ».",
              #"Type="[^"]*/(attachedTemplate|oleObject|frame|subDocument)"[^>]*Target="(https?:|file:|\\\\)[^"]*"[^>]*TargetMode="External"|Target="(https?:|file:|\\\\)[^"]*"[^>]*Type="[^"]*/(attachedTemplate|oleObject|frame|subDocument)"[^>]*TargetMode="External""#),
        Regle("doc.dde", .obfuscation, .elevee, .suspect, "Champ qui lance une commande (DDE)",
              "Ce champ fait lancer un programme par le traitement de texte, sans macro.", #"\bDDEAUTO\b|\bDDE\s+"?(cmd|powershell|mshta|c:\\)"#),
        Regle("doc.rtf-objet", .obfuscation, .moyenne, .suspect, "Objet embarqué dans un document RTF",
              "Un fichier est rangé dans le document comme objet ; « objupdate » le fait charger dès l'ouverture.", #"\\objupdate\b|\\objautlink\b|\\objdata\b"#, casse: true),
    ]

    // MARK: Installation (règles sur une ligne ; le reste est dans Installation.swift)

    static let installation: [Regle] = [
        Regle("inst.editeur", .installation, .elevee, .suspect, "Tâche lancée à l'ouverture du dossier",
              "Cette tâche s'exécute dès que le dossier est ouvert dans l'éditeur, sans rien demander.",
              #""runOn"\s*:\s*"folderOpen""#, noms: ["tasks.json"]),
        Regle("inst.pkg-verification", .installation, .moyenne, .suspect, "Le paquet lance un programme avant l'installation",
              "La fiche du paquet fait exécuter un script dès l'ouverture de l'installeur, avant même d'avoir cliqué sur « Installer ».",
              #"\bsystem\.run(Once)?\s*\("#, noms: ["distribution"]),
        Regle("inst.podspec", .installation, .moyenne, .suspect, "Commande lancée à l'installation (CocoaPods)",
              "Cette commande s'exécute pendant `pod install`.", #"\bprepare_command\b|\bscript_phase\b"#),
    ]
}

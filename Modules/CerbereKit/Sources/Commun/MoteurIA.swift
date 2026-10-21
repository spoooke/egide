import Foundation

public enum ErreurIA: Error, CustomStringConvertible, Equatable {
    case introuvable(String)
    case verrouillage(String)
    case quota(String)
    case echec(String)
    case reponseInvalide(String)

    public var description: String {
        switch self {
        case .introuvable(let chemin): "Claude Code introuvable (\(chemin))"
        case .verrouillage(let detail): "Lecture par IA refusée, le moteur n'est pas verrouillé : \(detail)"
        case .quota(let detail): "Quota de l'abonnement atteint : \(detail)"
        case .echec(let detail): "Lecture par IA impossible : \(detail)"
        case .reponseInvalide(let detail): "Réponse de l'IA illisible : \(detail)"
        }
    }
}

/// Ce que le moteur a déclaré à son lancement : la preuve du verrouillage.
public struct Lancement: Equatable, Sendable {
    public var outils: [String] = []
    public var connecteurs: [String] = []
    public var commandes: [String] = []
    public var competences: [String] = []
    public var dossier = ""
    public var modele = ""

    public var verrouille: Bool { outils.isEmpty && connecteurs.isEmpty && commandes.isEmpty && competences.isEmpty }
}

/// Un moteur d'IA : reçoit des consignes et un message, rend du texte. Rien d'autre (aucun outil).
public protocol MoteurIA: Sendable {
    var nom: String { get }
    /// À appeler une fois avant d'envoyer du code : échoue si le moteur n'est pas verrouillé.
    func verifier() throws
    func demander(consignes: String, message: String) throws -> String
}

/// Claude Code en ligne de commande (`claude -p`) avec l'abonnement. Seul domaine contacté : anthropic.com.
/// Verrouillé : aucun outil, aucun connecteur, réglages et fichiers d'instructions de la machine ignorés,
/// lancé depuis un dossier vide. Le code audité n'est jamais qu'un texte dans le message.
public struct ClaudeCLI: MoteurIA {
    public var executable: URL
    public var modele: String
    /// Durée maximale d'une question, en secondes.
    public var delai: TimeInterval = 900
    /// Dossier de lancement imposé (essais : un dossier piégé, pour prouver que son contenu est ignoré).
    var dossierImpose: URL? = nil
    /// Arrêt demandé par l'utilisateur : la question en cours est interrompue, les suivantes ne partent pas.
    public var annulation: Annulation? = nil

    public var nom: String { modele }

    public init(modele: String = "sonnet",
                executable: URL = Plateforme.claude,
                annulation: Annulation? = nil) {
        self.modele = modele
        self.executable = executable
        self.annulation = annulation
    }

    /// Options de verrouillage (voir `claude --help`) :
    /// - `--tools ""` : aucun outil intégré (ni commandes, ni fichiers, ni web) ;
    /// - `--strict-mcp-config` avec une liste vide : aucun connecteur ;
    /// - `--safe-mode`, `--setting-sources ""`, `--disable-slash-commands` : réglages, CLAUDE.md, hooks, extensions et compétences ignorés ;
    /// - `--system-prompt` : nos consignes remplacent celles de Claude Code ;
    /// - `--permission-mode dontAsk --permission-prompts none` : tout ce qui demanderait une permission est refusé ;
    /// - `--no-session-persistence` : la conversation (donc le code audité) n'est pas gardée sur le disque.
    func arguments(consignes: String) -> [String] {
        ["-p", "--safe-mode", "--tools", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
         "--setting-sources", "", "--disable-slash-commands", "--no-chrome", "--no-session-persistence",
         "--permission-mode", "dontAsk", "--permission-prompts", "none", "--model", modele,
         "--system-prompt", consignes, "--output-format", "stream-json", "--verbose"]
    }

    public func verifier() throws {
        _ = try lancer(consignes: "Tu es un essai de lancement. Réponds par le seul mot : ok", message: "ok ?")
    }

    public func demander(consignes: String, message: String) throws -> String {
        try lancer(consignes: consignes, message: message).texte
    }

    /// Lance `claude -p`, vérifie ce qu'il déclare au lancement et refuse toute réponse qui contient un appel d'outil.
    func lancer(consignes: String, message: String) throws -> (texte: String, lancement: Lancement) {
        let fm = FileManager.default
        try annulation?.verifier()
        guard fm.isExecutableFile(atPath: executable.path) else { throw ErreurIA.introuvable(executable.path) }
        let dossier = dossierImpose ?? fm.temporaryDirectory.appending(path: "cerbere-ia-\(UUID().uuidString)")
        if dossierImpose == nil {
            try fm.createDirectory(at: dossier, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        defer { if dossierImpose == nil { try? fm.removeItem(at: dossier) } }

        let processus = Process()
        processus.executableURL = executable
        processus.arguments = arguments(consignes: consignes)
        processus.currentDirectoryURL = dossier
        // Environnement minimal : pas de variables de la session, pas d'envoi de statistiques ni de mise à jour.
        processus.environment = Plateforme.environnementIA.merging([
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1",
            "DISABLE_AUTOUPDATER": "1",
        ]) { $1 }
        let entree = Pipe(), sortie = Pipe()
        processus.standardInput = entree
        processus.standardOutput = sortie
        processus.standardError = FileHandle.nullDevice
        do { try processus.run() } catch { throw ErreurIA.echec("\(error)") }
        annulation?.suivre(processus)
        defer { annulation?.oublier(processus) }
        // Écrire dans un autre fil : un long message remplirait le tuyau avant que claude ne le lise.
        let ecriture = entree.fileHandleForWriting
        let donnees = Data(message.utf8)
        DispatchQueue.global().async {
            try? ecriture.write(contentsOf: donnees)
            try? ecriture.close()
        }
        let garde = DispatchWorkItem { if processus.isRunning { processus.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + delai, execute: garde)
        let brut = sortie.fileHandleForReading.readDataToEndOfFile()
        processus.waitUntilExit()
        garde.cancel()
        try annulation?.verifier()
        return try Self.lire(brut, dossier: dossier)
    }

    /// Lit la sortie `stream-json` : une ligne JSON par événement.
    static func lire(_ brut: Data, dossier: URL) throws -> (texte: String, lancement: Lancement) {
        var lancement: Lancement?
        var resultat: [String: Any]?
        for ligne in brut.split(separator: UInt8(ascii: "\n")) {
            guard let e = try? JSONSerialization.jsonObject(with: Data(ligne)) as? [String: Any] else { continue }
            switch e["type"] as? String {
            case "system" where e["subtype"] as? String == "init":
                lancement = Lancement(
                    outils: e["tools"] as? [String] ?? ["?"],
                    connecteurs: (e["mcp_servers"] as? [[String: Any]])?.map { $0["name"] as? String ?? "?" } ?? ["?"],
                    commandes: e["slash_commands"] as? [String] ?? ["?"],
                    competences: e["skills"] as? [String] ?? ["?"],
                    dossier: e["cwd"] as? String ?? "", modele: e["model"] as? String ?? "")
            case "assistant":
                let contenu = (e["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                if let appel = contenu.first(where: { ($0["type"] as? String)?.hasSuffix("tool_use") == true }) {
                    throw ErreurIA.verrouillage("l'IA a tenté d'utiliser un outil (\(appel["name"] as? String ?? "?"))")
                }
            case "result": resultat = e
            default: break
            }
        }
        guard let lancement else { throw ErreurIA.echec("claude n'a rien répondu (délai dépassé ou non connecté)") }
        guard lancement.verrouille else {
            throw ErreurIA.verrouillage("outils \(lancement.outils), connecteurs \(lancement.connecteurs), commandes \(lancement.commandes), compétences \(lancement.competences)")
        }
        guard URL(fileURLWithPath: lancement.dossier).resolvingSymlinksInPath().path == dossier.resolvingSymlinksInPath().path else {
            throw ErreurIA.verrouillage("lancé depuis \(lancement.dossier)")
        }
        guard let resultat, let texte = resultat["result"] as? String else { throw ErreurIA.echec("réponse interrompue") }
        if resultat["is_error"] as? Bool == true {
            let t = texte.lowercased()
            if t.contains("limit") || t.contains("quota") || t.contains("overloaded") { throw ErreurIA.quota(String(texte.prefix(200))) }
            throw ErreurIA.echec(String(texte.prefix(200)))
        }
        return (texte, lancement)
    }
}

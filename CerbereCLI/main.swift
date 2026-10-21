// Cerbère en ligne de commande, sur le Mac et sur Windows : audit statique d'un dépôt (lien https), d'un paquet PyPI
// (archives téléchargées et ouvertes, jamais installées), ou d'un élément de la machine : dossier, archive, app, image
// disque, paquet d'installation, fichier. Sur Windows, --authenticode remplace --gatekeeper, le gestionnaire
// d'identifiants remplace le trousseau, et les apps, images disque et paquets du Mac ne sont pas ouverts.
//   cerbere <lien https | pypi:nom | dossier | archive | app | image disque | paquet | fichier> [--sortie <dossier>] [--garder] [--sans-ia] [--apercu] [--modele <nom>] [--lots <n>] [--gatekeeper] [--reputation] [--vulnerabilites | --sans-vulnerabilites]
//   cerbere --cle-virustotal | --oublier-cle-virustotal
//   cerbere --relais : attend les audits demandés depuis Égide sur l'iPhone (serveur Argos de ce Mac), sans fin.
// Rien n'est exécuté ni installé ; le rapport est écrit en JSON et en Markdown.
// Lecture par IA (Claude Code verrouillé, seul domaine : anthropic.com) : sans demander pour un lien public ou un
// paquet PyPI ; après accord à chaque audit pour un élément du Mac.
// --gatekeeper : verdict de Gatekeeper sur une app, une image ou un paquet (macOS peut interroger Apple).
// --reputation : l'empreinte SHA-256 du fichier (rien d'autre) est comparée à la base de www.virustotal.com.
// Ces deux options valent accord pour l'audit lancé, et pour lui seul.
// Vulnérabilités connues des dépendances (base OSV, api.osv.dev : écosystème, nom et version seulement) : sans demander
// pour un lien public ou un paquet PyPI (--sans-vulnerabilites pour s'en passer) ; pour un élément du Mac, seulement
// avec --vulnerabilites, qui vaut accord pour cet audit.
import Foundation

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--cle-virustotal"] {
    // La clé est tapée sans s'afficher, et rangée dans le coffre du système : elle n'apparaît ni dans l'historique du shell ni dans un fichier.
    guard let saisie = Console.saisieMasquee("Clé VirusTotal (la saisie ne s'affiche pas) : "), CleReputation.enregistrer(saisie) else {
        print("Clé non enregistrée (forme inattendue, ou \(CleReputation.coffre) refusé).")
        exit(2)
    }
    print("Clé rangée dans le \(CleReputation.coffre). Elle ne sert qu'avec --reputation, vers \(Reputation.domaine).")
    exit(0)
}
if arguments == ["--oublier-cle-virustotal"] {
    CleReputation.effacer()
    print("Clé retirée du \(CleReputation.coffre).")
    exit(0)
}
#if os(macOS)
if arguments == ["--relais"] {
    // Lancé par le service installé avec l'outil (scripts/install-cerbere.sh) ; tout est dit dans son journal.
    setvbuf(stdout, nil, _IOLBF, 0)
    print("Relais de Cerbère : en attente des demandes d'Égide (serveur Argos local).")
    RelaisDistant.reel().tourner { print("\(Date.now.formatted(.iso8601)) \($0)") }
}
#endif
/// Vérification de signature qui peut sortir de la machine : Gatekeeper sur le Mac, Authenticode sur Windows.
let optionSignature = Console.optionSignature
let gatekeeper = arguments.contains(optionSignature), reputation = arguments.contains("--reputation")
let vulnerabilites = arguments.contains("--vulnerabilites"), sansVulnerabilites = arguments.contains("--sans-vulnerabilites")
arguments.removeAll { [optionSignature, "--reputation", "--vulnerabilites", "--sans-vulnerabilites"].contains($0) }
let garder = arguments.contains("--garder")
arguments.removeAll { $0 == "--garder" }
var sortie: URL?
if let i = arguments.firstIndex(of: "--sortie"), i + 1 < arguments.count {
    sortie = URL(fileURLWithPath: (arguments[i + 1] as NSString).expandingTildeInPath)
    arguments.removeSubrange(i...i + 1)
}
let sansIA = arguments.contains("--sans-ia")
/// Montre ce qui serait envoyé à l'IA, sans rien envoyer.
let apercu = arguments.contains("--apercu")
arguments.removeAll { $0 == "--sans-ia" || $0 == "--apercu" }
var modele = "sonnet", lots = 6
if let i = arguments.firstIndex(of: "--modele"), i + 1 < arguments.count {
    modele = arguments[i + 1]
    arguments.removeSubrange(i...i + 1)
}
if let i = arguments.firstIndex(of: "--lots"), i + 1 < arguments.count {
    lots = Int(arguments[i + 1]) ?? 0
    arguments.removeSubrange(i...i + 1)
}
guard arguments.count == 1, !arguments[0].hasPrefix("-"), lots > 0 else {
    print("Usage : cerbere <lien https | pypi:nom | dossier | archive | \(Console.ciblesPropres) | fichier> [--sortie <dossier>] [--garder] [--sans-ia] [--apercu] [--modele <nom>] [--lots <n>] [\(optionSignature)] [--reputation] [--vulnerabilites | --sans-vulnerabilites]")
    print("        cerbere --cle-virustotal | --oublier-cle-virustotal")
    #if os(macOS)
    print("        cerbere --relais")
    #endif
    exit(2)
}
let cible = arguments[0]

@Sendable func dire(_ message: String) { FileHandle.standardError.write(Data("\(message)\n".utf8)) }
/// Journal du travail en cours, suivi en direct dans l'app Mac (fenêtre « Travail en cours »).
let journal = JournalAudit(origine: .outil, cible: cible)
/// Avancement de l'audit : seules les phrases sont affichées ; le détail va au journal.
@Sendable func suivre(_ a: Avancement) {
    journal.noter(a)
    if !a.message.isEmpty { dire(a.message) }
}

/// Lecture par IA après les règles. Un dossier ou une archive du Mac ne part qu'après un « oui » tapé à chaque audit.
let lectureIA: (Rapport, Inventaire) -> Rapport = { rapport, inventaire in
    let options = OptionsIA(lotsMax: lots)
    if apercu {
        let plan = LectureIA.planifier(inventaire, constats: rapport.constats, options: options)
        for (i, lot) in plan.lots.enumerated() {
            dire("Lot \(i + 1) (\(lot.taille / 1000) Ko) :")
            for m in lot.morceaux { dire("  \(m.chemin) lignes \(m.debut)-\(m.debut + m.lignes.count - 1) sur \(m.total)") }
        }
        let c = plan.couverture(lotsLus: Array(plan.lots.indices))
        dire("Aperçu : \(c.entiers) fichiers en entier et \(c.enPartie) en partie sur \(plan.lisibles), \(plan.secrets) secret(s) masqué(s). Rien n'a été envoyé.")
        return rapport
    }
    if Confidentialite.accordRequis(cible: cible) {
        let plan = LectureIA.planifier(inventaire, constats: rapport.constats, options: options)
        guard Console.interactif else {
            dire("Lecture par IA non faite : un élément de la machine demande un accord tapé au clavier.")
            return rapport
        }
        let ko = plan.lots.reduce(0) { $0 + $1.taille } / 1000
        dire("Lecture par IA : envoyer \(plan.lus.count) fichiers ou fiches tirés de cette cible (\(ko) Ko de texte, \(plan.secrets) secret(s) masqué(s)) à anthropic.com ? [o/N]")
        guard let reponse = readLine()?.lowercased(), ["o", "oui"].contains(reponse.trimmingCharacters(in: .whitespaces)) else {
            dire("Rien n'a été envoyé : règles automatiques seules.")
            return rapport
        }
    }
    return LectureIA.completerOuNoter(rapport, inventaire: inventaire, moteur: ClaudeCLI(modele: modele), options: options, suivi: suivre)
}

do {
    if cible.hasPrefix("pypi:") {
        _ = try Pypi.verifier(nom: String(cible.dropFirst(5)))
        dire("Téléchargement depuis pypi.org et files.pythonhosted.org (archives ouvertes en quarantaine, rien n'est installé)…")
    } else if cible.contains("://") {
        let url = try Quarantaine.verifier(lien: cible)
        dire("Récupération depuis \(url.host() ?? "?") (clone de quarantaine, rien n'est exécuté)…")
    }
    var enLigne = EnLigne()
    if gatekeeper || reputation {
        let nature = cible.contains("://") || cible.hasPrefix("pypi:") ? nil : Quarantaine.nature(de: (cible as NSString).expandingTildeInPath)
        guard let nature, nature != .dossier else {
            dire("\(optionSignature) et --reputation ne valent que pour \(Console.ciblesSignature).")
            exit(2)
        }
        if gatekeeper {
            enLigne.gatekeeper = true
            dire(Console.annonceSignature)
        }
        if reputation {
            guard let cle = CleReputation.lire() else {
                dire("Pas de clé VirusTotal dans le \(CleReputation.coffre) : lance d'abord « cerbere --cle-virustotal ».")
                exit(2)
            }
            enLigne.reputation = Reputation(cle: cle)
            dire("Réputation demandée : seule l'empreinte SHA-256 sera envoyée à \(Reputation.domaine).")
        }
    }
    // Les dépendances d'un dépôt public sont déjà publiques ; celles d'un élément du Mac ne partent qu'avec l'option.
    if Confidentialite.accordRequis(cible: cible) ? vulnerabilites : !sansVulnerabilites {
        enLigne.vulnerabilites = Vulnerabilites()
        dire("Vulnérabilités connues : seuls les noms et versions des dépendances seront envoyés à \(Vulnerabilites.domaine).")
    }
    let rapport = try Audit.auditer(cible, garder: garder, enLigne: enLigne, ia: sansIA ? nil : lectureIA, suivi: suivre)
    let dossier = sortie ?? Historique.nouveauDossier(cible: cible, date: rapport.date)
    try Audit.ecrire(rapport, dans: dossier)
    journal.terminer(verdict: rapport.verdict)
    print("Verdict : \(rapport.verdict.titre)")
    print(rapport.resume)
    for c in rapport.constats.filter({ !$0.ecarte }).prefix(15) {
        let lieu = c.lignes.isEmpty ? c.fichier : "\(c.fichier):\(c.lignes[0])"
        print("  \(c.id) [\(c.gravite.titre), \(c.statut == .confirme ? "confirmé" : "suspect")] \(c.titre) — \(lieu)")
    }
    if rapport.constats.count > 15 { print("  … et \(rapport.constats.count - 15) autres") }
    if garder { print("Quarantaine gardée dans \(Plateforme.cheminOutil(Quarantaine.racine.path))") }
    print("Rapport : \(Plateforme.cheminOutil(dossier.appending(path: "rapport.md").path))")
    exit(rapport.verdict == .nePasInstaller ? 1 : 0)
} catch {
    journal.terminer(erreur: error)
    dire("\(error)")
    exit(2)
}

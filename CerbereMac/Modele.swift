import CerbereKit
import EgideUI
import Foundation
import Observation

/// Ce que l'utilisateur a saisi ou glissé, lu sans rien contacter.
enum Saisie: Equatable {
    case vide
    /// Dépôt public : `hote` est le seul domaine contacté pour le récupérer.
    case lien(String, hote: String)
    case paquet(String)
    /// Élément de ce Mac, reconnu à son contenu : dossier, app, image disque, paquet, archive ou fichier.
    case local(String, nature: Quarantaine.Nature)
    case refusee(String)

    init(_ texte: String) {
        let t = texte.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { self = .vide }
        else if t.lowercased().hasPrefix("pypi:") {
            do { self = .paquet(try Pypi.verifier(nom: String(t.dropFirst(5)))) } catch { self = .refusee("\(error)") }
        } else if t.contains("://") {
            do { self = .lien(t, hote: try Quarantaine.verifier(lien: t).host() ?? "?") } catch { self = .refusee("\(error)") }
        } else {
            let chemin = (t as NSString).expandingTildeInPath
            if chemin.hasPrefix("/"), let nature = Quarantaine.nature(de: chemin) {
                self = .local(chemin, nature: nature)
            } else {
                self = .refusee("Ni un lien https://, ni un paquet « pypi:nom », ni un élément de ce Mac (dossier, app, image disque, paquet, archive, fichier).")
            }
        }
    }

    /// La cible telle que `Audit.auditer` l'attend.
    var cible: String? {
        switch self {
        case .lien(let lien, _): lien
        case .paquet(let nom): "pypi:\(nom)"
        case .local(let chemin, _): chemin
        case .vide, .refusee: nil
        }
    }

    /// Lien public ou paquet PyPI : son code et ses dépendances sont déjà publics.
    var publique: Bool {
        switch self {
        case .lien, .paquet: true
        default: false
        }
    }

    /// Les vérifications en ligne (Gatekeeper, réputation) ne valent que pour une app ou un fichier du Mac.
    var enLignePossible: Bool {
        if case .local(_, let nature) = self { return nature != .dossier }
        return false
    }
}

/// Réponse de l'utilisateur attendue par l'audit (qui tourne hors du fil principal).
final class Accord: @unchecked Sendable {
    private let attente = DispatchSemaphore(value: 0)
    private let verrou = NSLock()
    private var reponse: Bool?

    /// Seule la première réponse compte.
    func repondre(_ oui: Bool) {
        verrou.lock()
        let premiere = reponse == nil
        if premiere { reponse = oui }
        verrou.unlock()
        if premiere { attente.signal() }
    }

    func attendre() -> Bool {
        attente.wait()
        verrou.lock()
        defer { verrou.unlock() }
        return reponse ?? false
    }
}

struct EnCours {
    var nom: String
    var saisie: Saisie
    var avecIA: Bool
    var etape = Avancement.Etape.recuperation
    var message = ""
    var fait = 0
    var total = 0
    /// Aperçu de ce qui partirait à l'IA, tant que l'accord est attendu (dossier ou archive du Mac).
    var demande: LectureIA.Apercu?
    var arretDemande = false
    let annulation = Annulation()
    let accord = Accord()
}

@MainActor @Observable
final class Modele {
    static let nouveau = ""

    var audits: [AuditGarde] = []
    /// Ligne choisie dans la barre latérale : `nouveau` ou l'identifiant d'un audit gardé.
    var selection: String? = Modele.nouveau
    var comparaison: (ancien: AuditGarde, nouveau: AuditGarde)?
    var texte = ""
    var sansIA = UserDefaults.standard.bool(forKey: "cerbere.sansIA") { didSet { UserDefaults.standard.set(sansIA, forKey: "cerbere.sansIA") } }
    var lots = max(1, UserDefaults.standard.object(forKey: "cerbere.lots") as? Int ?? 6) { didSet { UserDefaults.standard.set(lots, forKey: "cerbere.lots") } }
    /// Accords donnés pour le prochain audit seulement : remis à zéro dès qu'il est lancé.
    var gatekeeper = false
    var reputation = false
    /// Base OSV pour un élément du Mac (pour un lien public ou un paquet PyPI, c'est sans demander).
    var vulnerabilites = false
    var aUneCle = CleReputation.existe
    var enCours: EnCours?
    var erreur: String?

    /// Range la clé VirusTotal dans le trousseau ; faux si elle n'en a pas la forme.
    func enregistrerCle(_ cle: String) -> Bool {
        let ok = CleReputation.enregistrer(cle)
        aUneCle = CleReputation.existe
        return ok
    }

    func oublierCle() {
        CleReputation.effacer()
        aUneCle = false
        reputation = false
    }

    init() { relire() }

    var auditChoisi: AuditGarde? { audits.first { $0.id == selection } }

    func relire() {
        let lus = EgideDemo.actif ? Historique.demo : Historique.lire()
        if lus != audits { audits = lus }
    }

    /// Audits en cours hors de cette app (demandes de l'iPhone, outil en ligne de commande).
    var auditsAilleurs = 0

    func surveiller() {
        if EgideDemo.actif { return }
        let ailleurs = JournalLu.lire().filter { $0.enCours && $0.origine != .app }.count
        if ailleurs < auditsAilleurs { relire() }   // l'un d'eux vient de finir : son rapport est rangé
        if ailleurs != auditsAilleurs { auditsAilleurs = ailleurs }
    }

    /// Autres audits de la même cible, le plus récent d'abord.
    func autresAudits(de audit: AuditGarde) -> [AuditGarde] {
        audits.filter { $0.id != audit.id && $0.rapport.cleCible == audit.rapport.cleCible }
    }

    func comparer(_ a: AuditGarde, _ b: AuditGarde) {
        comparaison = a.rapport.date <= b.rapport.date ? (a, b) : (b, a)
    }

    // MARK: - Audit

    func lancer() {
        let saisie = Saisie(texte)
        guard enCours == nil, let cible = saisie.cible else { return }
        erreur = nil
        // Ce qui sort du Mac en plus de l'IA : seulement si coché pour cet audit.
        var choix = EnLigne()
        if saisie.enLignePossible {
            choix.gatekeeper = gatekeeper
            if reputation {
                guard let cle = CleReputation.lire() else {
                    erreur = "Clé VirusTotal illisible dans le trousseau : rien n'a été lancé."
                    return
                }
                choix.reputation = Reputation(cle: cle)
            }
        }
        if saisie.publique || vulnerabilites { choix.vulnerabilites = Vulnerabilites() }
        gatekeeper = false
        reputation = false
        vulnerabilites = false
        let etat = EnCours(nom: cible, saisie: saisie, avecIA: !sansIA)
        enCours = etat
        let annulation = etat.annulation, accord = etat.accord, avecIA = !sansIA, options = OptionsIA(lotsMax: lots)
        let enLigne = choix
        // Du fil de l'audit vers le fil principal, dans l'ordre d'arrivée.
        let surLePrincipal: @Sendable (@escaping @MainActor @Sendable (Modele) -> Void) -> Void = { [self] action in
            DispatchQueue.main.async { MainActor.assumeIsolated { action(self) } }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let resultat = Result {
                try Self.auditer(cible, avecIA: avecIA, options: options, enLigne: enLigne, annulation: annulation, accord: accord,
                                 suivi: { a in surLePrincipal { $0.avancer(a) } },
                                 demander: { apercu in surLePrincipal { $0.enCours?.demande = apercu } })
            }
            surLePrincipal { $0.terminer(resultat) }
        }
    }

    /// L'audit lui-même, hors du fil principal : rend le dossier où le rapport est rangé.
    private nonisolated static func auditer(_ cible: String, avecIA: Bool, options: OptionsIA, enLigne: EnLigne, annulation: Annulation, accord: Accord,
                                            suivi: @escaping @Sendable (Avancement) -> Void,
                                            demander: @escaping @Sendable (LectureIA.Apercu?) -> Void) throws -> URL {
        let journal = JournalAudit(origine: .app, cible: cible)
        do {
            let dossier = try auditer(cible, avecIA: avecIA, options: options, enLigne: enLigne, annulation: annulation, accord: accord,
                                      journal: journal, suivi: journal.suivi(suivi), demander: demander)
            if let rapport = try? Rapport(json: Data(contentsOf: dossier.appending(path: "rapport.json"))) { journal.terminer(verdict: rapport.verdict) }
            return dossier
        } catch {
            journal.terminer(erreur: error)
            throw error
        }
    }

    private nonisolated static func auditer(_ cible: String, avecIA: Bool, options: OptionsIA, enLigne: EnLigne, annulation: Annulation, accord: Accord,
                                            journal: JournalAudit, suivi: @escaping @Sendable (Avancement) -> Void,
                                            demander: @escaping @Sendable (LectureIA.Apercu?) -> Void) throws -> URL {
        let rapport = try Audit.auditer(cible, annulation: annulation, enLigne: enLigne, ia: !avecIA ? nil : { regles, inventaire in
            // Dossier ou archive du Mac : rien ne part sans un accord donné pour cet audit, aperçu à l'appui.
            if Confidentialite.accordRequis(cible: cible) {
                let apercu = LectureIA.apercu(inventaire, constats: regles.constats, options: options)
                guard apercu.lots > 0 else { return regles }
                demander(apercu)
                journal.noter(Avancement(.lecture, "En attente de ton accord pour la lecture par IA…"))
                let oui = accord.attendre()
                demander(nil)
                journal.noter(Avancement(.lecture, lignes: [oui ? "Accord donné : lecture par IA." : "Pas d'accord : règles automatiques seules, rien n'est envoyé."]))
                guard oui else { return regles }
            }
            return LectureIA.completerOuNoter(regles, inventaire: inventaire, moteur: ClaudeCLI(annulation: annulation), options: options, suivi: suivi)
        }, suivi: suivi)
        let dossier = Historique.nouveauDossier(cible: cible, date: rapport.date)
        try Audit.ecrire(rapport, dans: dossier)
        return dossier
    }

    // MARK: - Expliqué simplement

    /// Audits dont l'explication simple est en train d'être rédigée, et dernière erreur par audit.
    var explications: Set<String> = []
    var erreursExplication: [String: String] = [:]

    /// Demande à l'IA d'expliquer le rapport en mots simples (le rapport seul, sans extrait de code), puis le réécrit.
    func expliquer(_ audit: AuditGarde) {
        guard !explications.contains(audit.id) else { return }
        explications.insert(audit.id)
        erreursExplication[audit.id] = nil
        let rapport = audit.rapport, dossier = audit.dossier, id = audit.id
        DispatchQueue.global(qos: .userInitiated).async {
            let resultat = Result {
                var r = rapport
                r.neophyte = try Neophyte.expliquer(rapport, moteur: ClaudeCLI())
                try Audit.ecrire(r, dans: dossier)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.explications.remove(id)
                    if case .failure(let e) = resultat { self.erreursExplication[id] = "\(e)" }
                    self.relire()
                }
            }
        }
    }

    // MARK: - Vérification ciblée (« check-up » d'un constat)

    /// Constats en cours de vérification (« dossier de l'audit#id ») et dernière erreur par constat.
    var verifications: Set<String> = []
    var erreursVerification: [String: String] = [:]

    func cle(_ audit: AuditGarde, _ id: String) -> String { "\(audit.id)#\(id)" }

    /// La cible est récupérée de nouveau en quarantaine, l'IA relit chaque passage avec son contexte, puis le rapport
    /// est réécrit (verdict recalculé par le code). Journal dans « Travail en cours ».
    func verifier(_ ids: [String], de audit: AuditGarde) {
        let ids = ids.filter { !verifications.contains(cle(audit, $0)) }
        guard !ids.isEmpty else { return }
        for id in ids {
            verifications.insert(cle(audit, id))
            erreursVerification[cle(audit, id)] = nil
        }
        let rapport = audit.rapport, dossier = audit.dossier, cles = ids.map { cle(audit, $0) }
        DispatchQueue.global(qos: .userInitiated).async {
            let journal = JournalAudit(origine: .app, cible: Verifications.cible(rapport))
            journal.noter(Avancement(.recuperation, "Vérification ciblée de \(ids.joined(separator: ", "))"))
            let resultat = Result {
                let r = try Verifications.verifier(ids, dans: rapport, moteur: ClaudeCLI(), suivi: journal.suivi())
                try Audit.ecrire(r.rapport, dans: dossier)
                journal.terminer(verdict: r.rapport.verdict)
                return r.echecs
            }
            if case .failure(let e) = resultat { journal.terminer(erreur: e) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for c in cles { self.verifications.remove(c) }
                    switch resultat {
                    case .success(let echecs): for (id, raison) in echecs { self.erreursVerification["\(audit.id)#\(id)"] = raison }
                    case .failure(let e): for c in cles { self.erreursVerification[c] = "\(e)" }
                    }
                    self.relire()
                }
            }
        }
    }

    func repondre(_ oui: Bool) { enCours?.accord.repondre(oui) }

    func annuler() {
        guard let enCours else { return }
        self.enCours?.arretDemande = true
        enCours.annulation.annuler()
        enCours.accord.repondre(false)
    }

    private func avancer(_ a: Avancement) {
        // Arrêt demandé : les lots interrompus ne sont pas des lots lus, l'affichage ne bouge plus.
        guard var etat = enCours, !etat.arretDemande else { return }
        etat.etape = max(etat.etape, a.etape)
        if !a.message.isEmpty { etat.message = a.message }
        if a.total > 0 {
            etat.total = a.total
            etat.fait = max(etat.fait, a.fait)
        }
        enCours = etat
    }

    private func terminer(_ resultat: Result<URL, Error>) {
        let etaitSurNouveau = selection == Modele.nouveau || selection == nil
        enCours = nil
        switch resultat {
        case .success(let dossier):
            texte = ""
            relire()
            if etaitSurNouveau { selection = dossier.path }
        case .failure(ErreurCerbere.annule): erreur = "Audit annulé : rien n'a été gardé."
        case .failure(let e): erreur = "\(e)"
        }
    }
}

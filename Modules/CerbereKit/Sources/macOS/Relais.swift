import Foundation

/// Relais des audits demandés depuis Égide sur l'iPhone (`cerbere --relais`, lancé à l'ouverture de session).
/// Il demande au serveur Argos de ce Mac (adresse locale, jeton des agents) la demande suivante, lance l'audit avec
/// les mêmes règles et la même lecture par IA que l'outil, range le rapport avec les autres, et le rend au serveur.
/// Une demande venue de l'extérieur n'est jamais crue : seuls un lien https public ou un paquet PyPI passent
/// (`CibleDistante`), donc rien de ce Mac ne peut être audité, ni envoyé à l'IA, par ce chemin.
public struct RelaisDistant: Sendable {
    public static let serveur = URL(string: "http://127.0.0.1:8787")!
    public static let jeton = URL.applicationSupportDirectory.appending(path: "Heartbit/data/agent-token")
    /// Secondes entre deux demandes de travail : une requête locale toutes les 10 s ne pèse rien.
    public static let intervalle = 10.0
    static let rapportMax = 4_000_000

    public struct Demande: Codable, Equatable, Sendable {
        public var id: String
        public var cible: String

        enum CodingKeys: String, CodingKey {
            case id, cible = "target"
        }
    }

    /// Envoi au serveur : chemin, corps JSON ; rend le code HTTP et la réponse (nil : serveur injoignable).
    public var envoyer: @Sendable (String, Data) -> (code: Int, corps: Data)?
    /// Audit d'une cible déjà contrôlée ; `suivi` reçoit l'avancement.
    public var auditer: @Sendable (String, Annulation, @escaping @Sendable (Avancement) -> Void) throws -> Rapport
    /// Où ranger le rapport sur le Mac (nil : nulle part, pour les essais).
    public var ranger: (@Sendable (Rapport, String) throws -> Void)?
    /// Secondes entre deux nouvelles données au serveur pendant un audit (c'est aussi là qu'on apprend une annulation).
    public var battement = 3.0

    public init(envoyer: @escaping @Sendable (String, Data) -> (code: Int, corps: Data)?,
                auditer: @escaping @Sendable (String, Annulation, @escaping @Sendable (Avancement) -> Void) throws -> Rapport,
                ranger: (@Sendable (Rapport, String) throws -> Void)? = nil) {
        self.envoyer = envoyer
        self.auditer = auditer
        self.ranger = ranger
    }

    /// Le relais réel : serveur Argos local, audit complet avec lecture par IA (un lien public ou un paquet PyPI
    /// part à l'IA sans demander, voir docs/cerbere.md).
    public static func reel(modele: String = "sonnet", lots: Int = 6) -> RelaisDistant {
        RelaisDistant(envoyer: poster, auditer: { cible, annulation, suiviServeur in
            // Le travail en cours se suit aussi sur le Mac, dans la fenêtre « Travail en cours » de l'app.
            let journal = JournalAudit(origine: .iphone, cible: cible)
            let suivi = journal.suivi(suiviServeur)
            do {
                let rapport = try auditerPourLIphone(cible, modele: modele, lots: lots, annulation: annulation, suivi: suivi)
                journal.terminer(verdict: rapport.verdict)
                return rapport
            } catch {
                journal.terminer(erreur: error)
                throw error
            }
        }, ranger: { rapport, cible in
            try Audit.ecrire(rapport, dans: Historique.nouveauDossier(cible: cible, date: rapport.date))
        })
    }

    private static func auditerPourLIphone(_ cible: String, modele: String, lots: Int, annulation: Annulation,
                                           suivi: @escaping @Sendable (Avancement) -> Void) throws -> Rapport {
        // Cible publique seulement (vérifié plus bas) : ses dépendances partent à la base OSV sans demander.
        var rapport = try Audit.auditer(cible, annulation: annulation, enLigne: EnLigne(vulnerabilites: Vulnerabilites()), ia: { rapport, inventaire in
            LectureIA.completerOuNoter(rapport, inventaire: inventaire, moteur: ClaudeCLI(modele: modele, annulation: annulation),
                                       options: OptionsIA(lotsMax: lots), suivi: suivi)
        }, suivi: suivi)
        // L'iPhone ne peut pas la demander après coup : l'explication simple est préparée ici, prête à être dépliée.
        if rapport.couches.ia {
            suivi(Avancement(.resume, "Explication en mots simples…"))
            rapport.neophyte = try? Neophyte.expliquer(rapport, moteur: ClaudeCLI(modele: modele, annulation: annulation))
            suivi(Avancement(.resume, lignes: [rapport.neophyte == nil ? "Explication en mots simples : échec, le rapport part sans elle." : "Explication en mots simples prête."]))
            try annulation.verifier()
        }
        return rapport
    }

    /// Demande suivante. `redemarrage` : premier appel depuis le lancement (un audit resté « en cours » est perdu).
    /// `.none` : serveur injoignable ou jeton absent ; `.some(nil)` : rien à faire.
    public func suivante(redemarrage: Bool) -> Demande?? {
        guard let reponse = envoyer("api/cerbere/next", Data(#"{"restart":\#(redemarrage)}"#.utf8)) else { return .none }
        switch reponse.code {
        case 204: return .some(nil)
        case 200: return (try? JSONDecoder().decode(Demande.self, from: reponse.corps)).map { .some($0) } ?? .none
        default: return .none
        }
    }

    /// Lance l'audit demandé et rend au serveur un rapport ou une erreur. Rend ce qui a été envoyé (essais).
    @discardableResult
    public func traiter(_ demande: Demande) -> Data {
        let chemin = "api/cerbere/audits/\(demande.id)"
        func rendre(erreur: String) -> Data {
            // Le texte d'une erreur peut venir du site distant (message de git) : une ligne, bornée.
            let texte = String(erreur.montrable.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(200))
            let corps = (try? JSONEncoder().encode(["error": texte])) ?? Data(#"{"error":"Erreur."}"#.utf8)
            _ = envoyer("\(chemin)/result", corps)
            return corps
        }
        let cible: String
        do { cible = try CibleDistante(demande.cible).cible } catch { return rendre(erreur: "Demande refusée par le Mac : \(error)") }
        // Ceinture et bretelles : ce qui demanderait un accord sur le Mac ne passe jamais par ici.
        guard !Confidentialite.accordRequis(cible: cible) else { return rendre(erreur: "Demande refusée par le Mac.") }

        let annulation = Annulation(), etape = Etape()
        let dire: @Sendable () -> Void = { [envoyer] in
            let corps = (try? JSONEncoder().encode(["step": etape.texte])) ?? Data("{}".utf8)
            guard let reponse = envoyer("\(chemin)/progress", corps), reponse.code == 200,
                  let lu = try? JSONDecoder().decode([String: Bool].self, from: reponse.corps) else { return }
            if lu["cancel"] == true { annulation.annuler() }
        }
        let horloge = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        horloge.schedule(deadline: .now() + battement, repeating: battement)
        horloge.setEventHandler(handler: dire)
        horloge.resume()
        defer { horloge.cancel() }
        do {
            let rapport = try auditer(cible, annulation) { avancement in
                guard !avancement.message.isEmpty else { return }
                etape.texte = String(avancement.message.prefix(150))
                dire()
            }
            try annulation.verifier()
            try ranger?(rapport, cible)
            let json = try rapport.json()
            guard json.count < Self.rapportMax else { return rendre(erreur: "Rapport trop gros pour l'iPhone : il est sur le Mac, dans l'app Cerbère.") }
            let corps = Data(#"{"report":"#.utf8) + json + Data("}".utf8)
            horloge.cancel()
            _ = envoyer("\(chemin)/result", corps)
            return corps
        } catch {
            horloge.cancel()
            return rendre(erreur: "\(error)")
        }
    }

    /// Boucle sans fin : une demande à la fois.
    public func tourner(journal: (String) -> Void) -> Never {
        var redemarrage = true
        while true {
            switch suivante(redemarrage: redemarrage) {
            case .none:
                break // serveur arrêté ou Argos non installé : on réessaie plus tard
            case .some(nil):
                redemarrage = false
            case .some(let demande?):
                redemarrage = false
                journal("Audit demandé depuis l'iPhone : \(demande.cible.montrable.prefix(CibleDistante.longueurMax))")
                traiter(demande)
                journal("Audit rendu.")
                continue
            }
            Thread.sleep(forTimeInterval: Self.intervalle)
        }
    }

    /// Envoi au serveur Argos de ce Mac. Le jeton est relu à chaque fois (Argos peut être installé plus tard).
    static let poster: @Sendable (String, Data) -> (code: Int, corps: Data)? = { chemin, corps in
        guard let jeton = try? String(contentsOf: jeton, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !jeton.isEmpty else { return nil }
        var requete = URLRequest(url: serveur.appending(path: chemin))
        requete.httpMethod = "POST"
        requete.httpBody = corps
        requete.timeoutInterval = 20
        requete.setValue("application/json", forHTTPHeaderField: "Content-Type")
        requete.setValue("Bearer \(jeton)", forHTTPHeaderField: "Authorization")
        let attente = DispatchSemaphore(value: 0), recu = Recu()
        session.dataTask(with: requete) { donnees, reponse, _ in
            if let http = reponse as? HTTPURLResponse { recu.valeur = (http.statusCode, donnees ?? Data()) }
            attente.signal()
        }.resume()
        attente.wait()
        return recu.valeur
    }

    private static let session: URLSession = {
        let reglages = URLSessionConfiguration.ephemeral
        reglages.connectionProxyDictionary = [:] // adresse locale : jamais par un proxy
        return URLSession(configuration: reglages)
    }()

    private final class Recu: @unchecked Sendable {
        var valeur: (code: Int, corps: Data)?
    }

    /// Dernière phrase d'avancement, lue par le battement.
    private final class Etape: @unchecked Sendable {
        private let verrou = NSLock()
        private var valeur = "Récupération…"
        var texte: String {
            get { verrou.withLock { valeur } }
            set { verrou.withLock { valeur = newValue } }
        }
    }
}

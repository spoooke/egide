import EgideUI
import SwiftUI

/// App Cerbère d'Égide : demander au Mac l'audit d'un dépôt public ou d'un paquet PyPI, et lire le rapport.
/// Tout passe par le serveur Argos (routes `/api/cerbere/…`) : l'iPhone ne récupère ni n'analyse rien lui-même.
public enum CerbereKit {
    public static let title = "Cerbère"
    public static let systemImage = "shield.lefthalf.filled"

    /// Appel du serveur Argos (chemin, méthode, corps JSON), branché par l'app sur la connexion d'Argos au
    /// lancement (EgideApp) ; renvoie nil quand Argos n'est pas connecté.
    @MainActor public static var serveur: @MainActor @Sendable (String, String, Data?) async throws -> Data? = { _, _, _ in nil }

    @MainActor static func liste() async throws -> ListeDistante? {
        try await serveur("api/cerbere/audits", "GET", nil).map { try Distant.decoder(ListeDistante.self, $0) }
    }

    @MainActor static func audit(_ id: String) async throws -> AuditDistant? {
        try await serveur("api/cerbere/audits/\(id)", "GET", nil).map { try Distant.decoder(AuditDistant.self, $0) }
    }

    @MainActor static func demander(_ cible: CibleDistante) async throws {
        _ = try await serveur("api/cerbere/audits", "POST", try JSONEncoder().encode(["target": cible.cible]))
    }

    /// Retire un audit ; s'il est en cours, le Mac l'arrête.
    @MainActor static func retirer(_ id: String) async throws {
        _ = try await serveur("api/cerbere/audits/\(id)", "DELETE", nil)
    }
}

/// Écran racine : lien à auditer, puis les audits demandés (du plus récent au plus ancien).
/// `path` : `["audit", "<lien>"]` quand un lien est partagé vers Cerbère (egide://cerbere/audit?lien=…).
public struct CerbereRootView: View {
    private enum Etat: Equatable {
        case chargement
        case nonConnecte
        case erreur(String)
        case recu(ListeDistante)
    }

    private let path: [String]
    private let request: Int
    private let onHome: (@MainActor @Sendable () -> Void)?
    @State private var etat = Etat.chargement
    @State private var texte = ""
    @State private var envoi = false
    @State private var message: String?
    /// Change après une demande : le suivi repart tout de suite, au rythme d'un audit en cours.
    @State private var relance = 0
    /// Rapports ouverts (identifiants d'audit) : vidé quand un lien partagé arrive, pour montrer le champ.
    @State private var ouverts: [String] = []
    @FocusState private var saisie: Bool

    /// `onHome` : bouton « Précédent » vers l'accueil d'Égide.
    public init(path: [String] = [], request: Int = 0, onHome: (@MainActor @Sendable () -> Void)? = nil) {
        self.path = path
        self.request = request
        self.onHome = onHome
    }

    private var cible: Result<CibleDistante, CibleDistante.Refus>? {
        texte.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : Result { () throws(CibleDistante.Refus) in try CibleDistante(texte) }
    }

    public var body: some View {
        NavigationStack(path: $ouverts) {
            List {
                Group {
                    Section {
                        nouvelAudit
                    } footer: {
                        Text("Rien n'est exécuté ni installé. Un audit statique baisse le risque, il ne prouve pas qu'un logiciel est sain.")
                    }
                    switch etat {
                    case .chargement:
                        Section { ProgressView().frame(maxWidth: .infinity) }
                    case .nonConnecte:
                        Section { Label("Argos n'est pas connecté : l'audit se fait sur le Mac, par le serveur Argos. Connecte d'abord l'app Argos d'Égide.", systemImage: "wifi.slash") }
                    case .erreur(let detail):
                        Section { Label { Text(verbatim: "Mac injoignable : \(detail)") } icon: { Image(systemName: "wifi.exclamationmark") } }
                    case .recu(let liste):
                        if !liste.relaisActif {
                            Section { Label("Le relais de Cerbère ne répond pas sur le Mac (Mac en veille, ou relais non installé) : une demande attendra son retour.", systemImage: "moon.zzz") }
                        }
                        if !liste.audits.isEmpty {
                            Section("Audits") { ForEach(liste.audits) { ligne($0) } }
                        }
                    }
                }
                .egideRow()
            }
            .egideList()
            .foregroundStyle(EgideTheme.encre)
            .navigationTitle(CerbereKit.title)
            .toolbar { HomeToolbarItem(action: onHome) }
            .navigationDestination(for: String.self) { VueRapportDistant(id: $0) }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await recharger() }
            // Un lien partagé remplit le champ et s'arrête là : rien ne part sans « Envoyer au Mac ».
            .onChange(of: request, initial: true) {
                if path.first == "audit", path.count > 1 {
                    texte = String(path[1].prefix(2000))
                    message = nil
                    ouverts = []
                }
            }
            // Audit en cours : avancement suivi de près ; sinon, un coup d'œil de temps en temps. S'arrête quand l'écran se ferme.
            .task(id: relance) {
                while !Task.isCancelled {
                    await recharger()
                    var actif = false
                    if case .recu(let liste) = etat { actif = liste.audits.contains(where: \.actif) }
                    try? await Task.sleep(for: .seconds(actif ? 4 : 20))
                }
            }
        }
    }

    @ViewBuilder
    private var nouvelAudit: some View {
        HStack(alignment: .firstTextBaseline) {
            TextField("Lien https ou pypi:nom", text: $texte, axis: .vertical)
                .lineLimit(1...4)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.callout.monospaced())
                .focused($saisie)
            if !texte.isEmpty {
                Button("Effacer", systemImage: "xmark.circle.fill") { texte = "" }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        if texte.isEmpty {
            // Bouton « Coller » système : pas de demande d'autorisation, iOS sait que l'utilisateur l'a touché.
            PasteButton(payloadType: String.self) { items in
                let colle = String((items.first ?? "").prefix(2000))
                Task { @MainActor in texte = colle }
            }
            .labelStyle(.titleAndIcon)
        }
        switch cible {
        case nil:
            Text("Colle le lien d'un dépôt public (GitHub, GitLab…) ou « pypi:nom », ou partage une page depuis Safari vers Égide.")
                .font(.footnote).foregroundStyle(.secondary)
        case .failure(let refus):
            Label { Text(verbatim: refus.description) } icon: { Image(systemName: "exclamationmark.triangle") }
                .font(.footnote).foregroundStyle(.orange)
        case .success(let cible):
            VStack(alignment: .leading, spacing: 6) {
                Text("Avant d'envoyer").font(.footnote.weight(.semibold))
                Text(verbatim: cible.cible.montrable).font(.footnote.monospaced())
                Text(verbatim: "Le Mac récupère ce code depuis \(cible.domaines.joined(separator: " et ")), puis en envoie des passages à anthropic.com pour la lecture par IA (code public : sans autre demande).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                Task { await envoyer(cible) }
            } label: {
                Label(envoi ? "Envoi…" : "Envoyer au Mac", systemImage: "paperplane.fill").frame(maxWidth: .infinity).foregroundStyle(.white)
            }
            .buttonStyle(.borderedProminent)
            .disabled(envoi)
        }
        if let message {
            Text(verbatim: message).font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func ligne(_ audit: AuditDistant) -> some View {
        let contenu = HStack(spacing: 12) {
            Group {
                switch audit.etat {
                case .attente: Image(systemName: "clock").foregroundStyle(.secondary)
                case .enCours: ProgressView()
                case .termine: Image(systemName: audit.verdict?.symbole ?? "doc.text").foregroundStyle(audit.verdict?.couleur ?? .gray)
                case .echec, .annule: Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                }
            }
            .font(.title3)
            .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: audit.nomCourt.montrable).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(verbatim: detail(audit)).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        Group {
            if audit.etat == .termine {
                NavigationLink(value: audit.id) { contenu }
            } else {
                contenu
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(audit.actif ? "Annuler" : "Supprimer", systemImage: audit.actif ? "stop.circle" : "trash", role: .destructive) {
                Task {
                    try? await CerbereKit.retirer(audit.id)
                    await recharger()
                }
            }
        }
    }

    private func detail(_ audit: AuditDistant) -> String {
        let quand = audit.demande.formatted(.relative(presentation: .named).locale(Locale(identifier: "fr_FR")))
        switch audit.etat {
        case .attente: return "En attente du Mac · demandé \(quand)"
        case .enCours: return audit.annulationDemandee == true ? "Arrêt demandé…" : (audit.etape ?? "En cours…").montrable
        case .termine: return "\(audit.verdict?.titre ?? "Rapport prêt") · \(quand)"
        case .echec: return "Non abouti · \((audit.erreur ?? "").montrable)"
        case .annule: return "Annulé"
        }
    }

    private func envoyer(_ cible: CibleDistante) async {
        envoi = true
        defer { envoi = false }
        do {
            try await CerbereKit.demander(cible)
            texte = ""
            saisie = false
            message = "Demande envoyée au Mac. Une notification d'Argos annoncera le rapport."
            relance += 1
        } catch {
            message = "Demande non envoyée : \(error.localizedDescription)"
        }
    }

    private func recharger() async {
        do {
            guard let liste = try await CerbereKit.liste() else {
                etat = .nonConnecte
                return
            }
            if etat != .recu(liste) { etat = .recu(liste) }
        } catch is CancellationError {
        } catch {
            // Une liste déjà affichée reste à l'écran.
            if case .recu = etat { return }
            etat = .erreur(error.localizedDescription)
        }
    }
}

// Services pour l'app : résumé de l'Accueil, sauvegarde globale.
extension CerbereKit {
    /// « Audit en cours », ou le verdict du dernier audit (nil si Argos n'est pas connecté, ou sans audit).
    @MainActor
    public static func summary() async -> String? {
        guard let audits = try? await liste()?.audits, let dernier = audits.first else { return nil }
        if let actif = audits.first(where: \.actif) { return "Audit en cours · \(actif.nomCourt.montrable)" }
        guard dernier.etat == .termine, let verdict = dernier.verdict else { return nil }
        return "\(verdict.titre) · \(dernier.nomCourt.montrable)"
    }

    /// Rien à sauvegarder : les rapports sont sur le Mac.
    @MainActor
    public static func backup() throws -> Data? { nil }

    @MainActor
    public static func restore(_ data: Data) throws -> String { "rien à restaurer" }
}

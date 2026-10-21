import Charts
import EgideUI
import SwiftUI

/// Onglet Héphaïstos d'Égide : la température, la mémoire et le disque du Mac, lus sur le serveur Argos (l'app du Mac y envoie une mesure par minute).
public enum HephaistosKit {
    public static let title = "Héphaïstos"
    public static let systemImage = "thermometer.medium"

    /// Lecture de GET /api/temperature, branchée par l'app sur la connexion d'Argos au lancement (EgideApp) ;
    /// renvoie nil quand Argos n'est pas connecté.
    @MainActor public static var charger: @MainActor @Sendable () async throws -> Data? = { nil }
}

/// Écran racine de l'onglet.
public struct HephaistosRootView: View {
    private enum Etat: Equatable {
        case chargement
        case nonConnecte
        case erreur(String)
        case recu(EtatDistant)
    }

    private let onHome: (@MainActor @Sendable () -> Void)?
    @State private var etat = Etat.chargement

    /// `onHome` : bouton « Précédent » vers l'accueil d'Égide.
    public init(path: [String] = [], request: Int = 0, onHome: (@MainActor @Sendable () -> Void)? = nil) {
        self.onHome = onHome
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    switch etat {
                    case .chargement:
                        ProgressView().padding(.top, 60)
                    case .nonConnecte:
                        message("Argos n'est pas connecté", "La température du Mac passe par le serveur Argos : connecte d'abord l'app Argos d'Égide.")
                    case .erreur(let texte):
                        message("Mac injoignable", texte)
                    case .recu(let distant):
                        if distant.date == nil {
                            message("Aucune mesure reçue", "Héphaïstos doit tourner sur le Mac (icône de température dans la barre des menus).")
                        } else {
                            resume(distant)
                            ressources(distant)
                            courbe(distant)
                            if let alerte = distant.alerte { derniere(alerte) }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .egideScreen()
            .foregroundStyle(EgideTheme.encre)
            .navigationTitle(HephaistosKit.title)
            .toolbar { HomeToolbarItem(action: onHome) }
            .refreshable { await recharger() }
            // Le Mac envoie une mesure par minute : inutile de demander plus souvent. S'arrête quand l'écran se ferme.
            .task {
                while !Task.isCancelled {
                    await recharger()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
    }

    private func recharger() async {
        do {
            guard let json = try await HephaistosKit.charger() else {
                etat = .nonConnecte
                return
            }
            etat = .recu(try EtatDistant(json: json))
        } catch is CancellationError {
        } catch {
            // Une mesure déjà affichée reste à l'écran : son heure dit qu'elle date.
            if case .recu = etat { return }
            etat = .erreur(error.localizedDescription)
        }
    }

    private func message(_ titre: String, _ texte: String) -> some View {
        ContentUnavailableView(titre, systemImage: HephaistosKit.systemImage, description: Text(texte))
            .padding(.top, 40)
    }

    private func resume(_ distant: EtatDistant) -> some View {
        let muet = distant.muet()
        return VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(EtatDistant.texte(distant.degres))
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(muet ? Color.secondary : EgideTheme.bleu)
                Text(distant.fraicheur() ?? "").font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if !muet {
                Jauge("Ventilateur",
                      distant.ventilateur < 1 ? "à l'arrêt" : "\(distant.ventilateur.formatted(.number.precision(.fractionLength(0)))) tr/min",
                      distant.ventilateurMaxi > 0 ? min(1, distant.ventilateur / distant.ventilateurMaxi) : 0)
                Jauge("Charge du processeur", distant.charge.formatted(.percent.precision(.fractionLength(0))), distant.charge)
                if let carte = distant.carteGraphique {
                    Jauge("Carte graphique", carte.texte, carte.utilisation)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .egideCard()
    }

    /// Mémoire (avec les apps qui en occupent le plus) et disque. Mac en veille : seul le disque garde un sens.
    @ViewBuilder
    private func ressources(_ distant: EtatDistant) -> some View {
        let memoire = distant.muet() ? nil : distant.memoire
        if memoire != nil || distant.disque != nil {
            VStack(spacing: 12) {
                if let memoire {
                    Jauge("Mémoire", memoire.texte, memoire.part)
                    VStack(spacing: 6) {
                        Ligne("Pression", memoire.pression.texte)
                        ForEach(Array((distant.appsMemoire ?? []).enumerated()), id: \.offset) { _, app in
                            Ligne(app.nom, Taille.memoire(app.octets))
                        }
                    }
                }
                if let disque = distant.disque {
                    Jauge("Disque", disque.texte, disque.part)
                }
            }
            .frame(maxWidth: .infinity)
            .egideCard()
        }
    }

    private func courbe(_ distant: EtatDistant) -> some View {
        let echelle = echelle(distant.historique)
        return VStack(spacing: 8) {
            EgideSectionTitle("Dernière heure")
            Chart(distant.historique) { point in
                // Aire posée sur le bas de l'échelle (qui ne part pas de zéro), sinon elle déborde sous la courbe.
                AreaMark(x: .value("Heure", point.date), yStart: .value("Bas", echelle.lowerBound), yEnd: .value("°C", point.degres))
                    .foregroundStyle(LinearGradient(colors: [EgideTheme.bleu.opacity(0.25), EgideTheme.bleu.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Heure", point.date), y: .value("°C", point.degres))
                    .foregroundStyle(EgideTheme.bleu)
            }
            .chartYScale(domain: echelle)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) } }
            .frame(height: 160)
        }
        .egideCard()
    }

    /// Échelle verticale : au moins 20 °C d'amplitude, pour qu'un degré d'écart ne ressemble pas à un pic.
    private func echelle(_ points: [EtatDistant.Point]) -> ClosedRange<Double> {
        let valeurs = points.map(\.degres)
        guard let mini = valeurs.min(), let maxi = valeurs.max() else { return 30...60 }
        let bas = (mini / 10).rounded(.down) * 10
        return bas...max(bas + 20, (maxi / 10).rounded(.up) * 10)
    }

    private func derniere(_ alerte: AlerteDistante) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            EgideSectionTitle("Dernière alerte")
            Text(alerte.titre).font(.callout.weight(.semibold))
            Text("\(alerte.resume) \(alerte.detail)").font(.footnote).foregroundStyle(.secondary)
            if let date = alerte.date {
                Text(date.formatted(.dateTime.weekday(.wide).hour().minute().locale(Locale(identifier: "fr_FR"))))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .egideCard()
    }
}

/// Nom à gauche, valeur à droite, et une barre de niveau de 0 à 1.
private struct Jauge: View {
    let nom: String
    let valeur: String
    let part: Double

    init(_ nom: String, _ valeur: String, _ part: Double) {
        self.nom = nom
        self.valeur = valeur
        self.part = part
    }

    var body: some View {
        VStack(spacing: 4) {
            Ligne(nom, valeur)
            ProgressView(value: part).tint(EgideTheme.bleu)
        }
    }
}

/// Nom à gauche, valeur à droite.
private struct Ligne: View {
    let nom: String
    let valeur: String

    init(_ nom: String, _ valeur: String) {
        self.nom = nom
        self.valeur = valeur
    }

    var body: some View {
        HStack {
            Text(nom).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text(valeur).monospacedDigit()
        }
        .font(.callout)
    }
}

// Services pour l'app : résumé de l'Accueil, sauvegarde globale.
extension HephaistosKit {
    /// « 62° · il y a 1 min » (nil si Argos n'est pas connecté, injoignable, ou sans mesure).
    @MainActor
    public static func summary() async -> String? {
        guard let json = try? await charger() else { return nil }
        return (try? EtatDistant(json: json))?.resume()
    }

    /// Rien à sauvegarder : les mesures sont sur le Mac.
    @MainActor
    public static func backup() throws -> Data? { nil }

    @MainActor
    public static func restore(_ data: Data) throws -> String { "rien à restaurer" }
}

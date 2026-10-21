import Charts
import EgideUI
import HephaistosKit
import ServiceManagement
import SwiftUI

/// Fenêtre de la barre des menus : résumé, courbe, ventilateur, charge, mémoire, disque, liste des capteurs, alertes et réglages.
struct Panneau: View {
    @Bindable var modele: HephaistosModele
    let notifications: Notifications
    /// Vrai dans l'onglet de la fenêtre d'Égide : ni en-tête ni largeur fixe, le contenu suit la fenêtre.
    var enOnglet = false
    @State private var ouvertureDeSession = SMAppService.mainApp.status == .enabled
    @State private var reglagesOuverts = false
    /// Hauteur du contenu, pour que la fenêtre s'y ajuste tant qu'elle tient à l'écran.
    @State private var hauteur = 400.0

    var body: some View {
        if enOnglet { colonnes } else { panneau }
    }

    /// Fenêtre de la barre des menus.
    private var panneau: some View {
        VStack(spacing: 12) {
            EgideHeader("Héphaïstos", sousTitre: "Températures du Mac", image: Image(nsImage: NSApp.applicationIconImage))
            // Au-delà de la hauteur de l'écran (sections dépliées), le contenu défile au lieu de sortir par le bas.
            ScrollView {
                VStack(spacing: 12) {
                    if let releve = modele.releve {
                        resume(releve)
                        courbe(releve)
                        jauges(releve)
                    }
                    capteurs
                    Depliable("Alertes et réglages", ouvert: $reglagesOuverts)
                    if reglagesOuverts {
                        alerte
                        reglages
                    }
                }
                .onGeometryChange(for: Double.self) { $0.size.height } action: { hauteur = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(hauteur, Self.hauteurMaxi))
        }
        .padding(16)
        .frame(width: 360)
        .foregroundStyle(EgideTheme.encre)
        .egideScreen()
        // Le modèle ne publie ses mesures que tant que la fenêtre est à l'écran.
        .background { SuiviDeFenetre { if modele.fenetreOuverte != $0 { modele.fenetreOuverte = $0 } } }
    }

    /// Onglet d'Égide : températures à gauche, ressources et réglages à droite, toujours dépliés.
    /// La visibilité de la fenêtre est suivie par Égide (FenetreEgide).
    private var colonnes: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 12) {
                    if let releve = modele.releve {
                        resume(releve)
                        courbe(releve)
                    }
                    capteurs
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 12) {
                    if let releve = modele.releve { jauges(releve) }
                    alerte
                    reglages
                }
                .frame(width: 340)
            }
            .padding(.bottom, 32)
        }
        .scrollBounceBehavior(.basedOnSize)
        .foregroundStyle(EgideTheme.encre)
        .tint(EgideTheme.bleu)
    }

    /// Place laissée au contenu sous la barre des menus : hauteur utile de l'écran, moins l'en-tête et les marges.
    private static var hauteurMaxi: Double {
        max(300, (NSScreen.main?.visibleFrame.height ?? 800) - 130)
    }

    private func resume(_ releve: Releve) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(spacing: 2) {
                Text(modele.chiffre)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(EgideTheme.bleu)
                Text("\(modele.affichage.rawValue), moyenne sur 10 s").font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 130)
            VStack(spacing: 6) {
                Ligne("Processeur", releve.processeurMoyenne.map { "\(degres($0)) (max \(degres(releve.processeurMax ?? $0)))" })
                Ligne("Puce graphique", releve.graphique.map(degres) ?? "au repos")
                Ligne("Batterie", releve.batterie.map(degres))
                Ligne("SSD", releve.ssd.map(degres))
            }
        }
        .egideCard()
    }

    private func courbe(_ releve: Releve) -> some View {
        VStack(spacing: 8) {
            EgideSectionTitle("10 dernières minutes")
            Chart(modele.historique) { point in
                AreaMark(x: .value("Heure", point.date), y: .value("°C", point.degres))
                    .foregroundStyle(LinearGradient(colors: [EgideTheme.bleu.opacity(0.25), EgideTheme.bleu.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Heure", point.date), y: .value("°C", point.degres))
                    .foregroundStyle(EgideTheme.bleu)
            }
            .chartXScale(domain: releve.date.addingTimeInterval(-HephaistosModele.duree)...releve.date)
            .chartYScale(domain: echelle)
            // La zone sous la courbe ne doit pas déborder de la carte quand l'historique est encore court.
            .chartPlotStyle { $0.clipped() }
            .chartXAxis { AxisMarks(values: .stride(by: .minute, count: 2)) { AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) } }
            .frame(height: 90)
        }
        .egideCard()
    }

    /// Échelle verticale : au moins 20 °C d'amplitude, pour qu'un degré d'écart ne ressemble pas à un pic.
    private var echelle: ClosedRange<Double> {
        let valeurs = modele.historique.map(\.degres)
        guard let mini = valeurs.min(), let maxi = valeurs.max() else { return 30...60 }
        let bas = (mini / 10).rounded(.down) * 10
        return bas...max(bas + 20, (maxi / 10).rounded(.up) * 10)
    }

    /// Ventilateur, charge du processeur, carte graphique, mémoire (avec les apps qui en occupent le plus) et disque.
    private func jauges(_ releve: Releve) -> some View {
        VStack(spacing: 10) {
            ForEach(Array(releve.ventilateurs.enumerated()), id: \.offset) { rang, ventilateur in
                Jauge(releve.ventilateurs.count > 1 ? "Ventilateur \(rang + 1)" : "Ventilateur",
                      ventilateur.toursParMinute < 1 ? "à l'arrêt" : "\(ventilateur.toursParMinute.formatted(.number.precision(.fractionLength(0)))) tr/min",
                      ventilateur.part)
            }
            if let charge = releve.charge {
                Jauge("Charge du processeur", charge.formatted(.percent.precision(.fractionLength(0))), charge)
            }
            if let carte = releve.carteGraphique {
                Jauge("Carte graphique", carte.texte, carte.utilisation)
            }
            if let memoire = releve.memoire {
                Jauge("Mémoire", "\(memoire.texte) · pression \(memoire.pression.texte)", memoire.part)
                VStack(spacing: 2) {
                    ForEach(Array((EgideDemo.actif ? Self.appsDemo : modele.apps).enumerated()), id: \.offset) { _, app in
                        Ligne(app.nom, Taille.memoire(app.octets)).font(.caption)
                    }
                }
            }
            if let disque = releve.disque {
                Jauge("Disque", disque.texte, disque.part)
            }
        }
        .egideCard()
    }

    private var capteurs: some View {
        VStack(spacing: 0) {
            Depliable("Tous les capteurs", ouvert: $modele.detail, carte: false)
            if modele.detail {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Famille.allCases, id: \.self) { famille in
                            let sondes = modele.sondes.filter { $0.famille == famille }
                            if !sondes.isEmpty {
                                EgideSectionTitle("\(famille.rawValue) (\(sondes.count))").padding(.top, 8)
                                ForEach(sondes) { sonde in
                                    Ligne(sonde.nom, sonde.degres.formatted(.number.precision(.fractionLength(1))) + "°")
                                }
                            }
                        }
                    }
                    .padding(.trailing, 12)
                }
                .frame(height: 220)
            }
        }
        .egideCard()
    }

    private var alerte: some View {
        VStack(spacing: 8) {
            Toggle("Alerter si le Mac chauffe trop", isOn: $modele.reglagesAlerte.active)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: modele.reglagesAlerte.active) { _, active in
                    if active { Task { await notifications.verifier() } }
                }
            if modele.reglagesAlerte.active {
                Stepper(value: $modele.reglagesAlerte.seuil, in: ReglagesAlerte.seuils, step: 5) {
                    Ligne("Au-dessus de", degres(modele.reglagesAlerte.seuil))
                }
                Picker("Pendant", selection: $modele.reglagesAlerte.duree) {
                    ForEach(ReglagesAlerte.durees, id: \.self) { Text(ReglagesAlerte.texte(duree: $0)).tag($0) }
                }
                HStack {
                    Spacer()
                    Button("Essayer l'alerte") { modele.essayerAlerte() }
                }
            }
            Toggle("Alerter si la mémoire sature", isOn: $modele.reglagesRessources.memoire)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: modele.reglagesRessources.memoire) { _, active in
                    if active { Task { await notifications.verifier() } }
                }
            Toggle("Alerter si le disque est presque plein", isOn: $modele.reglagesRessources.disque)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: modele.reglagesRessources.disque) { _, active in
                    if active { Task { await notifications.verifier() } }
                }
            if modele.reglagesRessources.disque {
                Stepper(value: $modele.reglagesRessources.seuilDisque, in: ReglagesRessources.seuilsDisque, step: 5) {
                    Ligne("Sous", "\(Int(modele.reglagesRessources.seuilDisque)) Go libres")
                }
            }
            if notifications.refusees {
                Text("Notifications coupées : les autoriser pour Héphaïstos dans Réglages Système > Notifications.")
                    .font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let dernier = modele.dernierAvis {
                Text("\(dernier.date.formatted(date: .omitted, time: .shortened)) · \(dernier.titre). \(dernier.message)")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.callout)
        .egideCard()
    }

    private var reglages: some View {
        VStack(spacing: 8) {
            Picker("Barre des menus", selection: $modele.affichage) {
                ForEach(Affichage.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Lancer à l'ouverture de session", isOn: $ouvertureDeSession)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: ouvertureDeSession) { _, actif in
                    do {
                        if actif { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        ouvertureDeSession = SMAppService.mainApp.status == .enabled
                    }
                }
            // Dans Égide, on quitte par le menu de la barre des menus.
            if !enOnglet {
                HStack {
                    Spacer()
                    Button("Quitter") { NSApplication.shared.terminate(nil) }
                }
            }
        }
        .font(.callout)
        .egideCard()
    }

    private func degres(_ valeur: Double) -> String { HephaistosModele.texte(valeur) }

    /// Mode démo : les apps qui occupent la mémoire ne sont pas les vraies.
    private static let appsDemo = [Occupation(nom: "Xcode", octets: 3.1e9), Occupation(nom: "Safari", octets: 1.4e9),
                                   Occupation(nom: "Aperçu", octets: 0.6e9)]
}

/// Nom à gauche, valeur à droite (« – » si elle manque).
private struct Ligne: View {
    let nom: String
    let valeur: String?

    init(_ nom: String, _ valeur: String?) {
        self.nom = nom
        self.valeur = valeur
    }

    var body: some View {
        HStack {
            Text(nom).foregroundStyle(.secondary)
            Spacer()
            Text(valeur ?? "–").monospacedDigit()
        }
        .font(police)
    }

    private var police = Font.callout

    func font(_ police: Font) -> Ligne {
        var copie = self
        copie.police = police
        return copie
    }
}

/// Titre d'une section qui se déplie au clic.
private struct Depliable: View {
    let titre: String
    @Binding var ouvert: Bool
    let carte: Bool

    init(_ titre: String, ouvert: Binding<Bool>, carte: Bool = true) {
        self.titre = titre
        _ouvert = ouvert
        self.carte = carte
    }

    var body: some View {
        if carte { bouton.egideCard() } else { bouton }
    }

    private var bouton: some View {
        Button {
            ouvert.toggle()
        } label: {
            HStack {
                Text(titre).font(.callout.weight(.semibold))
                Spacer()
                Image(systemName: ouvert ? "chevron.down" : "chevron.right").foregroundStyle(EgideTheme.bleu)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Ligne avec une barre de niveau de 0 à 1.
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

/// Signale quand la fenêtre qui porte la vue devient visible ou cesse de l'être. `onDisappear` ne suffit pas :
/// la fenêtre de la barre des menus est seulement masquée, son contenu reste en place.
struct SuiviDeFenetre: NSViewRepresentable {
    let visible: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> Vue {
        let vue = Vue()
        vue.visible = visible
        return vue
    }

    func updateNSView(_ vue: Vue, context: Context) {
        vue.visible = visible
    }

    final class Vue: NSView {
        var visible: (@MainActor (Bool) -> Void)?
        private var observateur: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observateur { NotificationCenter.default.removeObserver(observateur) }
            observateur = nil
            guard let window else {
                visible?(false)
                return
            }
            observateur = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                 object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.signaler() }
            }
            signaler()
        }

        private func signaler() {
            visible?(window?.occlusionState.contains(.visible) ?? false)
        }
    }
}

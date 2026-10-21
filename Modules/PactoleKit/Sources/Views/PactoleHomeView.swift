import EgideUI
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Accueil de Money : reste de la semaine en grand, dépenses de la semaine, accès aux autres vues.
struct PactoleHomeView: View {
    let route: PactoleRoute
    let request: Int
    /// Icône de l'en-tête sur le Mac (celle de l'outil dans Égide).
    var icone: Image?

    @Environment(\.modelContext) private var context
    @Environment(\.goHome) private var goHome
    @Query(sort: \Depense.date, order: .reverse) private var depenses: [Depense]
    @Query(sort: \Poste.ordre) private var postes: [Poste]
    @Query private var virements: [Virement]
    @AppStorage("money.plafondHebdoCentimes") private var plafondHebdo = 135_00
    @State private var saisie = false
    @State private var saisieRecu: SaisieRecu?
    @State private var lectureEnCours: String?
    @State private var erreurRecu: String?
    @State private var photo: PhotosPickerItem?
    @State private var choixFichier = false
    @State private var choixPhoto = false
    /// « Ajouter un relevé… » : le fichier choisi doit être un relevé (pas un reçu).
    @State private var attenteReleve = false
    @State private var planReleve: PlanReleve?
    @State private var erreurReleve: String?
    @State private var bilanReleve: String?
    private let recus = RecuEnAttente.shared
    @Environment(\.scenePhase) private var scenePhase

    private var nombreAVerifier: Int { depenses.filter(\.aVerifier).count }

    private var postesParID: [String: Poste] { Dictionary(postes.map { ($0.syncID, $0) }) { a, _ in a } }
    private var horsPlafond: Set<String> { Set(postes.filter(\.horsPlafondHebdo).map(\.syncID)) }

    var body: some View {
        NavigationStack {
            // Recalculé chaque minute : la semaine change le lundi, le montant par jour à minuit.
            TimelineView(.everyMinute) { contexte in
                #if os(macOS)
                tableau(contexte.date)
                #else
                liste(contexte.date)
                #endif
            }
            #if os(iOS)
            .navigationTitle(PactoleKit.title)
            .toolbar {
                HomeToolbarItem(action: goHome)
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink { ReglagesView() } label: { Label("Réglages", systemImage: "gearshape") }
                }
                ToolbarItem(placement: .primaryAction) { menuRecu }
                ToolbarItem(placement: .primaryAction) {
                    Button("Nouvelle dépense", systemImage: "plus") { saisie = true }
                }
            }
            #endif
            .sheet(isPresented: $saisie) { SaisieView() }
            .sheet(item: $saisieRecu) { SaisieView(brouillon: $0.brouillon) }
            .sheet(item: $planReleve) { releve in
                ReleveView(plan: releve.plan) { bilan in
                    bilanReleve = "\(bilan.liees) rapprochée(s), \(bilan.nouvelles) nouvelle(s) dépense(s), "
                        + "\(bilan.aVerifier) à vérifier, \(bilan.ignorees) ignorée(s), \(bilan.revenus) revenu(s) ajouté(s)."
                }
            }
            .overlay {
                if let lectureEnCours {
                    ProgressView(lectureEnCours).padding().background(.regularMaterial, in: .rect(cornerRadius: 12))
                }
            }
            .alert("Relevé non importé", isPresented: Binding { erreurReleve != nil } set: { if !$0 { erreurReleve = nil } }) {
                Button("OK") {}
            } message: {
                Text(erreurReleve ?? "")
            }
            .alert("Relevé ajouté", isPresented: Binding { bilanReleve != nil } set: { if !$0 { bilanReleve = nil } }) {
                Button("OK") {}
            } message: {
                Text(bilanReleve ?? "")
            }
            .alert("Reçu illisible", isPresented: Binding { erreurRecu != nil } set: { if !$0 { erreurRecu = nil } }) {
                Button("OK") {}
                Button("Saisir à la main") { saisie = true }
            } message: {
                Text(erreurRecu ?? "")
            }
            .fileImporter(isPresented: $choixFichier, allowedContentTypes: attenteReleve ? [.pdf] : PactoleKit.typesRecu) { resultat in
                guard case .success(let url) = resultat else { attenteReleve = false; return }
                if !PactoleKit.recevoirRecu(url) {
                    attenteReleve = false
                    erreurRecu = "Ce fichier n'est pas un reçu lisible."
                }
            }
            .photosPicker(isPresented: $choixPhoto, selection: $photo, matching: .images)
            .onChange(of: photo) { _, item in
                guard let item else { return }
                photo = nil
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        recus.deposer(data, type: item.supportedContentTypes.first ?? .image)
                    }
                }
            }
            // Mac : glisser un PDF (reçu ou relevé du mois), une capture ou un mail sur la fenêtre.
            .dropDestination(for: URL.self) { urls, _ in
                urls.first.map { PactoleKit.recevoirRecu($0) } ?? false
            }
            // Reçu partagé vers l'app, choisi ci-dessus ou glissé : lecture puis saisie pré-remplie.
            // Un relevé de compte PDF ouvre l'import du relevé du mois.
            .onChange(of: recus.fichier?.numero, initial: true) { _, _ in
                guard let fichier = recus.prendre() else { return }
                let releveAttendu = attenteReleve
                attenteReleve = false
                if fichier.type.conforms(to: .pdf), LectureReleve.estUnReleve(fichier.data) {
                    lireReleve(fichier.data)
                    return
                }
                if releveAttendu {
                    erreurReleve = Releve.Erreur.pasUnReleve.localizedDescription
                    return
                }
                saisie = false
                lectureEnCours = "Lecture du reçu…"
                Task {
                    defer { lectureEnCours = nil }
                    do {
                        let texte = try await LectureRecu.texte(de: fichier.data, type: fichier.type)
                        saisieRecu = SaisieRecu(brouillon: Recu.analyser(texte))
                    } catch {
                        erreurRecu = error.localizedDescription
                    }
                }
            }
            // Rattrapage des paiements écrits dans transactions.csv (à l'ouverture et au retour dans l'app).
            .onChange(of: scenePhase, initial: true) { _, phase in
                guard phase == .active else { return }
                #if os(iOS)
                _ = try? FichierSecours.lire(dans: context)
                #endif
                Task { await PactoleSync.shared.sync() }
            }
            // Lien egide://money/add : saisie éclair.
            .onChange(of: request, initial: true) { _, _ in
                if route == .add { saisie = true }
            }
        }
    }

    /// Lire un reçu : une capture ou une photo, ou un fichier (PDF, mail…).
    private var menuRecu: some View {
        Menu {
            // Pas de PhotosPicker dans un Menu : sur iOS, il disparaît avec le menu.
            Button("Capture ou photo…", systemImage: "photo") { choixPhoto = true }
            Button("Fichier (PDF, mail…)…", systemImage: "doc") { choixFichier = true }
        } label: {
            Label("Lire un reçu", systemImage: "doc.text.viewfinder")
        }
    }

    /// iPhone : une liste, la semaine en tête.
    private func liste(_ date: Date) -> some View {
        let semaine = Periodes.semaine(contenant: date)
        let cetteSemaine = depenses.filter { semaine.inclut($0.date) }
        return List {
            Group {
                Section {
                    SemaineView(semaine: Semaine(
                        plafond: Decimal(plafondHebdo) / 100,
                        depense: Decimal(Cumuls.totalSemaine(depenses, postesHorsPlafond: horsPlafond, semaine: semaine)) / 100,
                        aujourdhui: date))
                }
                .listRowBackground(Color.clear)

                if nombreAVerifier > 0 {
                    Section {
                        NavigationLink { AVerifierView() } label: {
                            Label("\(nombreAVerifier) paiement(s) à vérifier", systemImage: "exclamationmark.bubble")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    if cetteSemaine.isEmpty {
                        Text("Aucune dépense cette semaine.").foregroundStyle(.secondary)
                    }
                    ForEach(cetteSemaine) { depense in
                        DepenseRow(depense: depense, poste: postesParID[depense.posteID])
                            .menuDepense(depense, postes: postes, context: context)
                    }
                    .onDelete { supprimer(cetteSemaine, $0) }
                } header: {
                    Text("Cette semaine")
                } footer: {
                    let imprevu = cetteSemaine.filter { horsPlafond.contains($0.posteID) && $0.rembourseLe == nil }.reduce(0) { $0 + $1.montantCentimes }
                    if imprevu > 0 { Text("Dont \(Montant.texte(imprevu)) hors plafond (Imprévu).") }
                }

                // Suivi des plafonds du mois, en un coup d'œil (Imprévu seulement s'il y a une dépense).
                let mois = Periodes.mois(contenant: date)
                let totaux = Cumuls.parPoste(depenses, mois: mois)
                Section {
                    // Une seule ligne pour tous les virements du mois (le détail en la touchant).
                    let recu = virements.filter { mois.inclut($0.date) }.reduce(0) { $0 + $1.montantCentimes }
                    if recu > 0 {
                        NavigationLink { VirementsView(mois: mois) } label: {
                            HStack {
                                Label("Virements reçus", systemImage: "arrow.down.left.circle")
                                Spacer()
                                Text("+ " + Montant.texte(recu)).font(.callout.monospacedDigit()).bold()
                            }
                            .foregroundStyle(.green)
                        }
                    }
                    ForEach(postes.filter { $0.plafondMensuelCentimes != nil || (totaux[$0.syncID] ?? 0) > 0 }) { poste in
                        NavigationLink { DepensesPosteView(poste: poste, mois: mois) } label: {
                            LignePoste(poste: poste, total: totaux[poste.syncID] ?? 0)
                        }
                    }
                } header: {
                    Text("Par poste en " + date.formatted(Date.FormatStyle(locale: Locale(identifier: "fr_FR")).month(.wide).year()))
                }

                Section {
                    NavigationLink { SemainesView() } label: { Label("Semaines précédentes", systemImage: "calendar") }
                    NavigationLink { MoisView() } label: { Label("Bilan du mois", systemImage: "chart.bar") }
                    NavigationLink { TresorerieView() } label: { Label("Solde et paie", systemImage: "banknote") }
                    NavigationLink { SixMoisView() } label: { Label("Six derniers mois", systemImage: "chart.bar.xaxis") }
                }
            }
            .egideRow()
        }
        .egideList()
    }

    /// Lecture du relevé (hors du fil principal), puis ce que l'import va faire. Rien n'est gardé du PDF.
    private func lireReleve(_ data: Data) {
        saisie = false
        lectureEnCours = "Lecture du relevé…"
        Task {
            defer { lectureEnCours = nil }
            do {
                let pages = try await Task.detached { try LectureReleve.pages(data) }.value
                let releve = try Releve.analyser(pages)
                planReleve = PlanReleve(plan: try Rapprochement.preparer(releve, dans: context))
            } catch {
                erreurReleve = error.localizedDescription
            }
        }
    }

    private func supprimer(_ liste: [Depense], _ offsets: IndexSet) {
        for index in offsets { Suppressions.supprimer(liste[index], dans: context) }
        try? context.save()
    }
}

/// Import d'un relevé (une feuille par relevé lu).
private struct PlanReleve: Identifiable {
    let id = UUID()
    let plan: Rapprochement.Plan
}

/// Saisie ouverte depuis un reçu (une feuille par reçu lu).
private struct SaisieRecu: Identifiable {
    let id = UUID()
    let brouillon: BrouillonRecu
}

#if os(macOS)
/// Mac : en-tête avec les actions, la semaine et ses dépenses à gauche, le mois à droite.
extension PactoleHomeView {
    fileprivate func tableau(_ date: Date) -> some View {
        let semaine = Periodes.semaine(contenant: date)
        let cetteSemaine = depenses.filter { semaine.inclut($0.date) }
        let mois = Periodes.mois(contenant: date)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                EgideHeader(PactoleKit.title, sousTitre: "Budget de la semaine", image: icone) {
                    HStack(spacing: 8) {
                        NavigationLink { ReglagesView() } label: { Image(systemName: "gearshape") }
                            .help("Réglages")
                            .accessibilityLabel("Réglages")
                        menuRecu.fixedSize()
                        Button("Ajouter un relevé…", systemImage: "building.columns") {
                            attenteReleve = true
                            choixFichier = true
                        }
                        .help("Relevé du mois (PDF Société Générale) : glisser le PDF sur la fenêtre marche aussi.")
                        Button("Nouvelle dépense", systemImage: "plus") { saisie = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .labelStyle(.titleAndIcon)
                }
                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 18) {
                        SemaineView(semaine: Semaine(
                            plafond: Decimal(plafondHebdo) / 100,
                            depense: Decimal(Cumuls.totalSemaine(depenses, postesHorsPlafond: horsPlafond, semaine: semaine)) / 100,
                            aujourdhui: date))
                            .egideCard(padding: 20, cornerRadius: 24)
                        depensesDeLaSemaine(cetteSemaine)
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: 18) {
                        postesDuMois(mois, date: date)
                        Carte("Historique") {
                            Lien { SemainesView() } label: { Label("Semaines précédentes", systemImage: "calendar") }
                            Lien { MoisView() } label: { Label("Bilan du mois", systemImage: "chart.bar") }
                            Lien { TresorerieView() } label: { Label("Solde et paie", systemImage: "banknote") }
                            Lien { SixMoisView() } label: { Label("Six derniers mois", systemImage: "chart.bar.xaxis") }
                        }
                    }
                    .frame(width: 340)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 44)
            .padding(.bottom, 32)
            .frame(maxWidth: 1040, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(EgideTheme.encre)
        .egideScreen()
        .toolbar(removing: .title)
    }

    private func depensesDeLaSemaine(_ liste: [Depense]) -> some View {
        Carte("Dépenses de la semaine") {
            if nombreAVerifier > 0 {
                Lien { AVerifierView() } label: {
                    Label("\(nombreAVerifier) paiement(s) à vérifier", systemImage: "exclamationmark.bubble").foregroundStyle(.orange)
                }
            }
            if liste.isEmpty {
                Text("Aucune dépense cette semaine.").foregroundStyle(.secondary)
            }
            ForEach(Array(liste.enumerated()), id: \.element.id) { rang, depense in
                if rang > 0 { Divider() }
                DepenseRow(depense: depense, poste: postesParID[depense.posteID])
                    .contentShape(.rect)
                    .menuDepense(depense, postes: postes, context: context)
            }
            let imprevu = liste.filter { horsPlafond.contains($0.posteID) && $0.rembourseLe == nil }.reduce(0) { $0 + $1.montantCentimes }
            if imprevu > 0 {
                Text("Dont \(Montant.texte(imprevu)) hors plafond (Imprévu).").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func postesDuMois(_ mois: DateInterval, date: Date) -> some View {
        let totaux = Cumuls.parPoste(depenses, mois: mois)
        let recu = virements.filter { mois.inclut($0.date) }.reduce(0) { $0 + $1.montantCentimes }
        return Carte("Postes en " + date.formatted(Date.FormatStyle(locale: Locale(identifier: "fr_FR")).month(.wide))) {
            if recu > 0 {
                Lien { VirementsView(mois: mois) } label: {
                    HStack {
                        Label("Virements reçus", systemImage: "arrow.down.left.circle")
                        Spacer()
                        Text("+ " + Montant.texte(recu)).font(.callout.monospacedDigit()).bold()
                    }
                    .foregroundStyle(.green)
                }
            }
            ForEach(postes.filter { $0.plafondMensuelCentimes != nil || (totaux[$0.syncID] ?? 0) > 0 }) { poste in
                Lien { DepensesPosteView(poste: poste, mois: mois) } label: {
                    LignePoste(poste: poste, total: totaux[poste.syncID] ?? 0)
                }
            }
        }
    }
}

/// Carte du tableau : un titre, puis des lignes.
private struct Carte<Contenu: View>: View {
    let titre: String
    let contenu: Contenu

    init(_ titre: String, @ViewBuilder contenu: () -> Contenu) {
        self.titre = titre
        self.contenu = contenu()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(titre).font(.headline)
            contenu
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .egideCard(padding: 20, cornerRadius: 24)
    }
}

/// Ligne qui ouvre un écran, avec un chevron à droite.
private struct Lien<Destination: View, Etiquette: View>: View {
    let destination: Destination
    let etiquette: Etiquette

    init(@ViewBuilder destination: () -> Destination, @ViewBuilder label: () -> Etiquette) {
        self.destination = destination()
        etiquette = label()
    }

    var body: some View {
        NavigationLink { destination } label: {
            HStack {
                etiquette.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
#endif

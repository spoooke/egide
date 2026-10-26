import CerbereKit
import EgideUI
import SwiftUI

/// Fenêtre « Travail en cours » : les audits en cours (app, outil en ligne de commande, demandes de l'iPhone) et les
/// derniers finis, avec leur journal en direct : fichiers lus, constats trouvés, lots envoyés à l'IA et ses réponses,
/// relecture. Relu chaque seconde depuis les journaux du disque. Tout ce qui vient du code audité est du texte brut.
struct VueTravail: View {
    @State private var journaux: [JournalLu] = []
    @State private var choisi: String?
    /// Le journal défile tout seul jusqu'en bas, sauf si on remonte le lire.
    @State private var suivreLaFin = true
    private let horloge = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var journal: JournalLu? { journaux.first { $0.id == choisi } ?? journaux.first }

    var body: some View {
        NavigationSplitView {
            List(selection: $choisi) {
                let enCours = journaux.filter(\.enCours), finis = journaux.filter { !$0.enCours }
                Section("En cours") {
                    if enCours.isEmpty { Text("Aucun audit en cours").foregroundStyle(.secondary) }
                    ForEach(enCours) { LigneJournal(journal: $0).tag($0.id) }
                }
                if !finis.isEmpty { Section("Dernières 24 h") { ForEach(finis) { LigneJournal(journal: $0).tag($0.id) } } }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            Group {
                if let journal { detail(journal) } else {
                    ContentUnavailableView("Rien pour l'instant", systemImage: "waveform.path.ecg",
                                           description: Text("Les audits lancés dans l'app, avec l'outil cerbere ou depuis l'iPhone apparaîtront ici pendant qu'ils tournent."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(EgideTheme.encre)
            .egideScreen()
        }
        .onAppear(perform: relire)
        .onReceive(horloge) { _ in relire() }
    }

    private func relire() {
        let lus = JournalLu.lire()
        if lus != journaux { journaux = lus }
        // Un nouvel audit qui démarre prend la place d'un audit fini.
        if let premier = lus.first, premier.enCours, journaux.first(where: { $0.id == choisi })?.enCours != true { choisi = premier.id }
    }

    private func detail(_ j: JournalLu) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: j.origine.symbole).font(.title2).foregroundStyle(EgideTheme.bleu)
                    Text(verbatim: j.cible.montrable).font(.title3.monospaced().weight(.semibold)).lineLimit(1).truncationMode(.middle)
                }
                Text(verbatim: "\(j.origine.titre) · commencé à \(j.debut.formatted(date: .omitted, time: .standard))\(j.fin.map { " · fini à \($0.formatted(date: .omitted, time: .standard))" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
                etat(j)
                if j.enCours, j.etape == .lecture, j.total > 0 {
                    ProgressView(value: Double(j.fait), total: Double(j.total)) { Text("Lots lus par l'IA : \(j.fait) sur \(j.total)").font(.caption) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .egideCard()

            HStack {
                EgideSectionTitle("Journal (\(j.lignes.count) lignes)")
                Toggle("Suivre la fin", isOn: $suivreLaFin).toggleStyle(.checkbox).font(.caption)
            }
            ScrollViewReader { defilement in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(j.lignes.enumerated()), id: \.offset) { i, ligne in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: ligne.date.formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(verbatim: ligne.texte.montrable)
                                    .font(ligne.etape ? .callout.weight(.semibold) : .callout.monospaced())
                                    .foregroundStyle(couleur(ligne))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id(i)
                        }
                        Color.clear.frame(height: 1).id("fin")
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(EgideTheme.carte, in: EgideTheme.forme())
                .overlay(EgideTheme.forme().stroke(EgideTheme.contour))
                .onChange(of: j.lignes.count) { if suivreLaFin { defilement.scrollTo("fin", anchor: .bottom) } }
                .onChange(of: j.id) { defilement.scrollTo("fin", anchor: .bottom) }
                .onAppear { defilement.scrollTo("fin", anchor: .bottom) }
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func etat(_ j: JournalLu) -> some View {
        if let verdict = j.verdict {
            Label(verdict.titre, systemImage: verdict.symbole).foregroundStyle(verdict.couleur).font(.headline)
        } else if let erreur = j.erreur {
            Text(verbatim: erreur.montrable).foregroundStyle(.red).font(.callout)
        } else if j.interrompu {
            Text("Interrompu : le programme qui faisait l'audit s'est arrêté avant la fin.").foregroundStyle(.secondary).font(.callout)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(verbatim: j.message.isEmpty ? "En cours…" : j.message.montrable).font(.callout)
            }
        }
    }

    /// Constats colorés par gravité ; le reste en encre.
    private func couleur(_ l: JournalLu.Ligne) -> Color {
        if l.etape { return EgideTheme.encre }
        for g in [Gravite.critique, .elevee] where l.texte.contains("[\(g.titre) · ") { return g.couleur }
        if l.texte.contains("échec") { return .red }
        return EgideTheme.encre
    }
}

private struct LigneJournal: View {
    let journal: JournalLu

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: journal.origine.symbole).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: nomCourt.montrable).lineLimit(1).truncationMode(.middle)
                Text(verbatim: sousTitre).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if journal.enCours { ProgressView().controlSize(.mini) }
            else if let v = journal.verdict { Circle().fill(v.couleur).frame(width: 9, height: 9) }
        }
    }

    /// « auteur/dépôt », nom du paquet, ou dernier élément du chemin.
    private var nomCourt: String {
        let c = journal.cible
        if c.hasPrefix("pypi:") { return String(c.dropFirst(5)) }
        let morceaux = c.split(separator: "/").map(String.init)
        return c.contains("://") ? morceaux.dropFirst(2).suffix(2).joined(separator: "/") : (morceaux.last ?? c)
    }

    private var sousTitre: String {
        let heure = journal.debut.formatted(date: .omitted, time: .shortened)
        if journal.enCours { return "\(journal.origine.titre) · \(heure) · \(journal.message.isEmpty ? "en cours" : journal.message)" }
        return "\(journal.origine.titre) · \(heure) · \(journal.verdict?.titre ?? (journal.interrompu ? "interrompu" : "erreur"))"
    }
}

extension JournalAudit.Origine {
    var titre: String {
        switch self {
        case .app: "App Mac"
        case .outil: "Outil cerbere"
        case .iphone: "Depuis l'iPhone"
        }
    }

    var symbole: String {
        switch self {
        case .app: "macwindow"
        case .outil: "terminal"
        case .iphone: "iphone"
        }
    }
}

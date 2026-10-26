import EgideUI
import SwiftUI

/// Accueil d'Égide, comme sur le Mac : la date en titre, les outils en rangée sous le pouce (ordre choisi dans
/// Réglages), puis une carte par outil avec ce qu'il a à dire aujourd'hui. Toucher une icône ou une carte ouvre l'outil.
struct HomeView: View {
    @Binding var layout: TabLayout
    @Binding var showsSettings: Bool
    let zoom: Namespace.ID
    let open: (Module) -> Void
    /// Résumé de chaque app, rafraîchi à chaque affichage de l'accueil.
    @State private var summaries: [Module: String] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Égide").font(.subheadline.weight(.medium)).foregroundStyle(EgideTheme.bleu)
                            Text(Self.date)
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(EgideTheme.encre)
                                .minimumScaleFactor(0.7)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button("Réglages", systemImage: "gearshape") { showsSettings = true }
                            .buttonStyle(.egideRound)
                    }

                    outils

                    // La première carte en grand, les suivantes plus sobres ; les outils sans nouvelles tiennent sur une ligne.
                    let avecNouvelles = layout.visible.filter { !(summaries[$0] ?? "").isEmpty }
                    let sansNouvelles = layout.visible.filter { (summaries[$0] ?? "").isEmpty }
                    VStack(spacing: 12) {
                        ForEach(Array(avecNouvelles.enumerated()), id: \.element) { rang, module in
                            Button { open(module) } label: { carte(module, principale: rang == 0) }
                                .buttonStyle(.plain)
                        }
                    }
                    if !sansNouvelles.isEmpty {
                        Text("Rien de neuf dans " + ListFormatter.localizedString(byJoining: sansNouvelles.map(\.title)) + ".")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .egideScreen()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showsSettings) {
                SettingsView(layout: $layout)
            }
            .onAppear { loadSummaries() }
            .refreshable { loadSummaries() }
        }
    }

    /// « Lundi 19 octobre ».
    private static var date: String {
        let texte = Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "fr_FR")))
        return texte.prefix(1).uppercased() + texte.dropFirst()
    }

    /// Un résumé par app, en parallèle : Argos interroge son serveur, les autres répondent tout de suite.
    private func loadSummaries() {
        for module in layout.visible {
            Task { summaries[module] = await module.summary() }
        }
    }

    /// Les outils sur une bande blanche, comme la colonne d'outils du Mac couchée à l'horizontale.
    private var outils: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                ForEach(layout.visible) { module in
                    Button { open(module) } label: {
                        VStack(spacing: 6) {
                            Image(module.iconName)
                                .resizable()
                                .egideIconFrame(48)
                                .matchedTransitionSource(id: module, in: zoom)
                            Text(module.title)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(EgideTheme.encre)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(width: 64)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(module.title)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .background(EgideTheme.carte, in: EgideTheme.forme(rayon: 22))
        .overlay(EgideTheme.forme(rayon: 22).stroke(EgideTheme.contour))
        .shadow(color: EgideTheme.ombre, radius: 12, y: 4)
    }

    /// Carte d'un outil : son nom et un lien à droite, puis son résumé, en grand pour la première.
    private func carte(_ module: Module, principale: Bool) -> some View {
        VStack(alignment: .leading, spacing: principale ? 10 : 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(module.title, systemImage: module.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(principale ? EgideTheme.bleu : EgideTheme.encre)
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(EgideTheme.bleu)
            }
            Text(summaries[module] ?? "")
                .font(principale ? .system(.title, design: .rounded, weight: .bold) : .body.weight(.medium))
                .foregroundStyle(EgideTheme.encre)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .egideCard(padding: principale ? 20 : 16, cornerRadius: 22)
        .contentShape(.rect)
        .accessibilityHint("Ouvre \(module.title)")
    }
}

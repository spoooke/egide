import EgideUI
import PactoleKit
import SwiftUI

/// Menu de l'icône d'Égide dans la barre des menus : l'état du Mac, la semaine de Pactole, et l'accès aux onglets.
/// Aucun montant dans la barre elle-même : seulement à l'ouverture du menu.
struct BarreDesMenus: View {
    let etat: EtatEgide
    @Environment(\.openWindow) private var ouvrirFenetre
    @State private var semaine: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image("Icone-egide").resizable().egideIconFrame(28)
                Text("Égide").font(.system(.title3, design: .rounded, weight: .bold))
                Spacer()
                Text(etat.hephaistos.texte).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(EgideTheme.bleu)
            }
            if let semaine {
                Button { ouvrir(.pactole) } label: {
                    Label(semaine, systemImage: Onglet.pactole.symbole).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            Divider()
            HStack {
                ForEach(Onglet.allCases.filter { $0 != .accueil }) { onglet in
                    Button { ouvrir(onglet) } label: { Image(systemName: onglet.symbole) }
                        .help(onglet.titre)
                }
                Spacer()
                Button("Ouvrir Égide") { ouvrir(.accueil) }.buttonStyle(.borderedProminent)
                Button("Quitter") { NSApplication.shared.terminate(nil) }
            }
        }
        .font(.callout)
        .padding(14)
        .frame(width: 340)
        .foregroundStyle(EgideTheme.encre)
        .tint(EgideTheme.bleu)
        .task { semaine = await PactoleKit.summary() }
    }

    private func ouvrir(_ onglet: Onglet) {
        etat.onglet = onglet
        ouvrirFenetre(id: "main")
        NSApplication.shared.activate()
    }
}

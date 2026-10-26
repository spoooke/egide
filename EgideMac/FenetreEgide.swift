import EgideUI
import ArgosKit
import PactoleKit
import MuseKit
import MnemosyneKit
import SwiftUI

/// Fenêtre principale : la colonne d'outils à gauche, l'onglet ouvert à droite, sur le fond dégradé d'Égide.
struct FenetreEgide: View {
    @Bindable var etat: EtatEgide

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Colonne(onglet: $etat.onglet)
                .padding(.leading, 14)
                // Sous les boutons de la fenêtre (fermer, réduire, agrandir).
                .padding(.top, 38)
                .padding(.bottom, 14)
            contenu
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(EgideTheme.encre)
        .egideScreen()
        .ignoresSafeArea(.container, edges: .top)
        .task { Captures.lancerSiDemande(etat) }
        // Héphaïstos ne publie ses mesures détaillées que si quelqu'un les regarde.
        .background {
            SuiviDeFenetre { visible in
                if etat.hephaistos.fenetreOuverte != visible { etat.hephaistos.fenetreOuverte = visible }
            }
        }
    }

    @ViewBuilder private var contenu: some View {
        switch etat.onglet {
        case .accueil:
            Accueil(etat: etat)
        case .hephaistos:
            Onglet.page(.hephaistos) {
                Panneau(modele: etat.hephaistos, notifications: etat.notifications, enOnglet: true)
                    .frame(maxWidth: 976)
            }
        case .pactole:
            PactoleRootView(icone: Image(Onglet.pactole.icone))
                .onOpenURL { PactoleKit.recevoirRecu($0) }
        case .muse:
            MuseRootView()
                .environment(\.egideIcone, Image(Onglet.muse.icone))
        case .iris:
            IrisMac()
        case .cerbere:
            Fenetre(modele: etat.cerbere, enOnglet: true)
        case .mnemosyne:
            Onglet.page(.mnemosyne) {
                MnemosyneView(model: etat.mnemosyne)
                    .frame(maxWidth: 976)
            }
        case .argos:
            ArgosRootView()
                .environment(\.egideIcone, Image(Onglet.argos.icone))
        case .hermes:
            HermesMac()
        }
    }
}

extension Onglet {
    /// Page d'un outil : en-tête avec son icône, puis son contenu, aligné à gauche.
    @MainActor static func page<Contenu: View>(_ onglet: Onglet, @ViewBuilder contenu: () -> Contenu) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            EgideHeader(onglet.titre, sousTitre: onglet.sousTitre, image: Image(onglet.icone))
                .frame(maxWidth: 976)
            contenu()
        }
        .padding(.horizontal, 32)
        .padding(.top, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Colonne d'outils : une bande blanche détachée du bord, l'icône d'Égide en haut, un bouton par outil.
private struct Colonne: View {
    @Binding var onglet: Onglet

    var body: some View {
        VStack(spacing: 10) {
            Image("Icone-egide")
                .resizable()
                .egideIconFrame(34)
                .padding(.top, 14)
                .padding(.bottom, 10)
            ForEach(Onglet.allCases) { o in
                Button { onglet = o } label: { bouton(o) }
                    .buttonStyle(.plain)
                    .help(o.titre)
                    .accessibilityLabel(o.titre)
                    .accessibilityAddTraits(o == onglet ? .isSelected : [])
            }
            Spacer()
        }
        .frame(width: 58)
        .frame(maxHeight: .infinity)
        .background(EgideTheme.carte, in: EgideTheme.forme(rayon: 22))
        .overlay(EgideTheme.forme(rayon: 22).stroke(EgideTheme.contour))
        .shadow(color: EgideTheme.ombre, radius: 12, y: 4)
    }

    private func bouton(_ o: Onglet) -> some View {
        let choisi = o == onglet
        return Image(systemName: o.symbole)
            .font(.system(size: 15, weight: choisi ? .semibold : .regular))
            .foregroundStyle(choisi ? EgideTheme.surBleu : EgideTheme.encre.opacity(0.6))
            .frame(width: 38, height: 38)
            .background(choisi ? EgideTheme.bleu : .clear, in: EgideTheme.formeRonde)
            .contentShape(EgideTheme.formeRonde)
    }
}

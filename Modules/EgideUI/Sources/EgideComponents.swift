import SwiftUI

/// Fond d'écran d'Égide : dégradé vertical, sous les barres comprises.
public struct EgideBackground: View {
    public init() {}

    public var body: some View {
        LinearGradient(colors: [EgideTheme.fondHaut, EgideTheme.fondBas], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

public extension View {
    /// Écran dans le thème : fond dégradé et accent bleu.
    func egideScreen() -> some View {
        background { EgideBackground() }
            .tint(EgideTheme.bleu)
    }

    /// Liste ou formulaire dans le thème : fond dégradé à la place du gris (lignes : `egideRow()`).
    func egideList() -> some View {
        scrollContentBackground(.hidden)
            .egideScreen()
    }

    /// Lignes de liste posées sur une carte du thème : sans effet sur la liste elle-même, à mettre sur
    /// une ligne, une section ou un `Group` qui enveloppe tout le contenu de la liste.
    func egideRow() -> some View {
        listRowBackground(EgideTheme.carte)
    }

    /// Carte blanche aux coins arrondis, contour fin et ombre légère.
    func egideCard(padding: CGFloat? = 14, cornerRadius: CGFloat = EgideTheme.rayonCarte) -> some View {
        self.padding(padding.map { EdgeInsets(top: $0, leading: $0, bottom: $0, trailing: $0) } ?? EdgeInsets())
            .background(EgideTheme.carte, in: EgideTheme.forme(rayon: cornerRadius))
            .overlay(EgideTheme.forme(rayon: cornerRadius).stroke(EgideTheme.contour))
            .shadow(color: EgideTheme.ombre, radius: 10, y: 4)
    }

    /// Icône d'app : coins arrondis, contour et ombre comme sur l'écran d'accueil.
    func egideIconFrame(_ taille: CGFloat) -> some View {
        frame(width: taille, height: taille)
            .clipShape(.rect(cornerRadius: taille * 0.25, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: taille * 0.25, style: .continuous).stroke(EgideTheme.contour))
            .shadow(color: EgideTheme.ombre.opacity(1.6), radius: taille / 10, y: taille / 20)
    }
}

/// Titre de section discret : petites capitales espacées, en bleu.
public struct EgideSectionTitle: View {
    let texte: String

    public init(_ texte: String) { self.texte = texte }

    public var body: some View {
        Text(texte.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(EgideTheme.bleu.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// En-tête d'écran : image (logo ou icône), titre arrondi, sous-titre bleu, et un bouton à droite.
public struct EgideHeader<Accessoire: View>: View {
    let image: Image?
    let titre: String
    let sousTitre: String?
    let accessoire: Accessoire

    public init(_ titre: String, sousTitre: String? = nil, image: Image? = nil,
                @ViewBuilder accessoire: () -> Accessoire = { EmptyView() }) {
        self.titre = titre
        self.sousTitre = sousTitre
        self.image = image
        self.accessoire = accessoire()
    }

    public var body: some View {
        HStack(spacing: 12) {
            if let image {
                image.resizable().egideIconFrame(44)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(titre)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(EgideTheme.encre)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let sousTitre {
                    Text(sousTitre).font(.subheadline).foregroundStyle(EgideTheme.bleu)
                }
            }
            Spacer(minLength: 0)
            accessoire
        }
    }
}

/// Bouton rond translucide (réglages, ajout…) pour les en-têtes.
public struct EgideRoundButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.title3)
            .foregroundStyle(EgideTheme.bleu)
            .frame(width: 40, height: 40)
            .background(EgideTheme.carte.opacity(0.85), in: EgideTheme.formeRonde)
            .overlay(EgideTheme.formeRonde.stroke(EgideTheme.contour))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Bouton principal (plein, bleu) ou secondaire (carte, texte bleu), en capsule.
public struct EgideButtonStyle: ButtonStyle {
    let principal: Bool

    public init(principal: Bool = true) { self.principal = principal }

    public func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, principal: principal)
    }

    // The enabled state is only readable from a view's environment, not from the configuration.
    private struct StyledLabel: View {
        let configuration: Configuration
        let principal: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(principal ? EgideTheme.surBleu : EgideTheme.bleu)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(principal ? EgideTheme.bleu : EgideTheme.carte, in: EgideTheme.formeBouton)
                .overlay(EgideTheme.formeBouton.stroke(EgideTheme.contour))
                .shadow(color: EgideTheme.ombre, radius: 8, y: 3)
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
        }
    }
}

public extension ButtonStyle where Self == EgideButtonStyle {
    static var egide: EgideButtonStyle { EgideButtonStyle() }
    static var egideSecondary: EgideButtonStyle { EgideButtonStyle(principal: false) }
}

public extension ButtonStyle where Self == EgideRoundButtonStyle {
    static var egideRound: EgideRoundButtonStyle { EgideRoundButtonStyle() }
}

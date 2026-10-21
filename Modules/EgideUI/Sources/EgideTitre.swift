import SwiftUI

public extension View {
    /// Titre d'un écran ouvert depuis l'écran principal d'un outil. Sur iPhone, le titre de la barre de navigation ;
    /// sur Mac, un en-tête dans la page (bouton Retour, titre en grand), comme les onglets d'Égide Mac.
    func egideTitre(_ titre: String) -> some View {
        #if os(iOS)
        navigationTitle(titre)
        #else
        modifier(EnTeteMac(titre: titre))
        #endif
    }
}

#if os(macOS)
private struct EnTeteMac: ViewModifier {
    let titre: String
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { dismiss() } label: {
                Label("Retour", systemImage: "chevron.left").font(.callout.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(EgideTheme.bleu)
            .keyboardShortcut("[", modifiers: .command)
            .help("Revenir (⌘[)")
            Text(titre)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(EgideTheme.encre)
                .lineLimit(1)
            content
                .frame(maxWidth: 760, alignment: .leading)
        }
        .padding(.horizontal, 32)
        .padding(.top, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .egideScreen()
        .navigationTitle(titre)
        .navigationBarBackButtonHidden(true)
        .toolbar(removing: .title)
    }
}
#endif

private struct IconeKey: EnvironmentKey {
    static let defaultValue: Image? = nil
}

public extension EnvironmentValues {
    /// Icône de l'outil, pour l'en-tête de son écran principal sur Mac (donnée par Égide Mac).
    var egideIcone: Image? {
        get { self[IconeKey.self] }
        set { self[IconeKey.self] = newValue }
    }
}

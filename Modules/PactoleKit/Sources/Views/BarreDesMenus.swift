import SwiftData
import SwiftUI

#if os(macOS)
/// Icône de Money dans la barre des menus du Mac. Aucun montant affiché (confidentialité) :
/// le reste de la semaine n'apparaît qu'en ouvrant le menu.
public struct PactoleMenuBarLabel: View {
    public init() {}

    public var body: some View {
        Image(systemName: PactoleKit.systemImage)
            .accessibilityLabel(PactoleKit.title)
    }
}

/// Fenêtre de la barre des menus : reste de la semaine, saisie éclair, ouverture de Money.
public struct PactoleMenuBarContent: View {
    private let ouvrir: () -> Void

    /// `ouvrir` : affiche la fenêtre principale de Money.
    public init(ouvrir: @escaping () -> Void) {
        self.ouvrir = ouvrir
    }

    public var body: some View {
        ContenuBarre(ouvrir: ouvrir).modelContainer(PactoleDatabase.container).defaultAppStorage(PactoleReglages.defaults)
    }
}

private struct ContenuBarre: View {
    let ouvrir: () -> Void
    @Query private var depenses: [Depense]
    @Query private var postes: [Poste]
    @AppStorage("money.plafondHebdoCentimes") private var plafondHebdo = 135_00
    @State private var saisie = false

    var body: some View {
        if saisie {
            SaisieView(terminer: { saisie = false })
                .frame(width: 340, height: 460)
        } else {
            let semaine = Semaine(plafond: Decimal(plafondHebdo) / 100,
                                  depense: Decimal(plafondHebdo - reste(depenses, postes, plafondHebdo, .now)) / 100,
                                  aujourdhui: .now)
            VStack(spacing: 12) {
                SemaineView(semaine: semaine)
                let aVerifier = depenses.filter(\.aVerifier).count
                if aVerifier > 0 {
                    Text("\(aVerifier) paiement(s) à vérifier").font(.callout).foregroundStyle(.orange)
                }
                HStack {
                    Button("Nouvelle dépense", systemImage: "plus") { saisie = true }
                        .buttonStyle(.borderedProminent)
                    Button("Ouvrir Pactole", action: ouvrir)
                    Spacer()
                    Button("Quitter") { NSApplication.shared.terminate(nil) }
                }
            }
            .padding()
            .frame(width: 340)
        }
    }
}

/// Reste de la semaine en centimes (sans les postes hors plafond).
@MainActor
private func reste(_ depenses: [Depense], _ postes: [Poste], _ plafond: Int, _ date: Date) -> Int {
    let horsPlafond = Set(postes.filter(\.horsPlafondHebdo).map(\.syncID))
    return plafond - Cumuls.totalSemaine(depenses, postesHorsPlafond: horsPlafond, semaine: Periodes.semaine(contenant: date))
}
#endif

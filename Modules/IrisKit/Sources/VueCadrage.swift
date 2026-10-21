import EgideUI
import SwiftUI

/// Une photo importée à cadrer : l'image à l'endroit, les coins proposés par Vision (nil : aucun document vu).
struct IrisImport: Identifiable {
    let id = UUID()
    let image: CGImage
    let detectes: IrisCoins?
}

/// Cadrage des photos importées, une à une : les 4 coins proposés, déplaçables au doigt.
/// `fin` reçoit les coins choisis pour chaque image, ou nil si on annule.
struct VueCadrage: View {
    let imports: [IrisImport]
    let fin: @MainActor ([IrisCoins]?) -> Void
    @State private var index = 0
    @State private var choisis: [IrisCoins]

    init(imports: [IrisImport], fin: @escaping @MainActor ([IrisCoins]?) -> Void) {
        self.imports = imports
        self.fin = fin
        _choisis = State(initialValue: imports.map { $0.detectes ?? .entier })
    }

    private var courant: IrisImport { imports[index] }
    private var dernier: Bool { index == imports.count - 1 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                CadreCoins(image: courant.image, coins: $choisis[index])
                    .id(courant.id)
                Text(courant.detectes == nil && choisis[index] == .entier
                     ? "Aucun document repéré : place les coins sur ses bords."
                     : "Fais glisser les coins sur les bords du document.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Image entière", systemImage: "arrow.up.left.and.arrow.down.right") {
                        choisis[index] = .entier
                    }
                    .disabled(choisis[index] == .entier)
                    if let detectes = courant.detectes {
                        Spacer()
                        Button("Bords détectés", systemImage: "viewfinder") { choisis[index] = detectes }
                            .disabled(choisis[index] == detectes)
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .egideScreen()
            .navigationTitle(imports.count > 1 ? "Page \(index + 1) sur \(imports.count)" : "Cadrage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { fin(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(dernier ? "Valider" : "Suivante") {
                        if dernier { fin(choisis) } else { index += 1 }
                    }
                    .disabled(!choisis[index].valide)
                }
            }
        }
    }
}

/// L'image, le quadrilatère des coins et 4 poignées à faire glisser.
private struct CadreCoins: View {
    let image: CGImage
    @Binding var coins: IrisCoins
    /// Position d'un coin au début du glissement : il suit le doigt sans sauter dessous.
    @State private var depart: CGPoint?

    /// Marge autour de l'image : on attrape une poignée même au bord.
    private let marge: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let cadre = rectangle(dans: geo.size)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: cadre.width, height: cadre.height)
                    .offset(x: cadre.minX, y: cadre.minY)
                Path { trace in
                    trace.addLines(coins.points.map { ecran($0, cadre) })
                    trace.closeSubpath()
                }
                .fill(EgideTheme.bleu.opacity(0.18))
                Path { trace in
                    trace.addLines(coins.points.map { ecran($0, cadre) })
                    trace.closeSubpath()
                }
                .stroke(coins.valide ? EgideTheme.bleu : .red, lineWidth: 2)
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(.white.opacity(0.35))
                        .strokeBorder(coins.valide ? EgideTheme.bleu : .red, lineWidth: 3)
                        .frame(width: 2 * marge, height: 2 * marge)
                        .contentShape(Circle())
                        .position(ecran(coins.points[i], cadre))
                        .gesture(DragGesture(minimumDistance: 0).onChanged { glisse in
                            let origine = depart ?? coins.points[i]
                            depart = origine
                            coins.points[i] = CGPoint(x: min(max(origine.x + glisse.translation.width / cadre.width, 0), 1),
                                                      y: min(max(origine.y + glisse.translation.height / cadre.height, 0), 1))
                        }.onEnded { _ in depart = nil })
                        .accessibilityLabel(["Coin haut gauche", "Coin haut droite", "Coin bas droite", "Coin bas gauche"][i])
                }
            }
        }
    }

    /// Place de l'image, ajustée à l'écran en gardant ses proportions.
    private func rectangle(dans taille: CGSize) -> CGRect {
        let dispo = CGSize(width: max(taille.width - 2 * marge, 1), height: max(taille.height - 2 * marge, 1))
        let echelle = min(dispo.width / CGFloat(image.width), dispo.height / CGFloat(image.height))
        let largeur = CGFloat(image.width) * echelle, hauteur = CGFloat(image.height) * echelle
        return CGRect(x: (taille.width - largeur) / 2, y: (taille.height - hauteur) / 2, width: largeur, height: hauteur)
    }

    private func ecran(_ p: CGPoint, _ cadre: CGRect) -> CGPoint {
        CGPoint(x: cadre.minX + p.x * cadre.width, y: cadre.minY + p.y * cadre.height)
    }
}

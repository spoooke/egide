import Observation
import SwiftUI

/// Charte d'Égide, tirée de la famille d'icônes : fond blanc → bleu pâle, trait bleu, coins arrondis, ombres légères.
/// Chaque couleur a sa variante sombre (bleu nuit, bleu plus lumineux).
/// A second palette, Night City, can replace it (always dark: black, neon yellow, cyan, red, cut corners).
public enum EgideTheme {
    /// Bleu du trait des icônes (#3F74D9) : accent, liens, boutons.
    public static var bleu: Color { nuit ? Color(hex: 0xFCEE0A) : Classique.bleu }
    /// Texte principal, bleu très foncé plutôt que noir.
    public static var encre: Color { nuit ? Color(hex: 0x5EF6FF) : Classique.encre }
    /// Haut et bas du fond dégradé (#FFFFFF → #DCE9FB).
    public static var fondHaut: Color { nuit ? Color(hex: 0x0A0A10) : Classique.fondHaut }
    public static var fondBas: Color { nuit ? Color(hex: 0x1C0A14) : Classique.fondBas }
    /// Cartes posées sur le fond.
    public static var carte: Color { nuit ? Color(hex: 0x14111B) : Classique.carte }
    /// Contour fin des cartes et des icônes.
    public static var contour: Color { nuit ? Color(hex: 0xFF003C).opacity(0.55) : Classique.bleu.opacity(0.10) }
    /// Ombre bleutée, très légère.
    public static var ombre: Color { nuit ? .clear : Classique.ombre }
    /// Text and icons drawn on top of `bleu` (white on blue, near-black on neon yellow).
    public static var surBleu: Color { nuit ? Color(hex: 0x0A0A10) : .white }

    public static let rayonCarte: CGFloat = 18

    public static var palette: EgidePalette { EgideApparence.shared.palette }

    /// Card outline: rounded in the classic palette, two cut corners in Night City.
    public static func forme(rayon: CGFloat = rayonCarte) -> AnyShape {
        nuit ? AnyShape(CoinsCoupes(taille: min(rayon * 0.7, 16))) : AnyShape(.rect(cornerRadius: rayon, style: .continuous))
    }

    /// Button outline: capsule in the classic palette.
    public static var formeBouton: AnyShape {
        nuit ? AnyShape(CoinsCoupes(taille: 10)) : AnyShape(.capsule)
    }

    /// Small round controls (header buttons, selected tab).
    public static var formeRonde: AnyShape {
        nuit ? AnyShape(CoinsCoupes(taille: 9)) : AnyShape(.circle)
    }

    private static var nuit: Bool { palette == .nightCity }

    private enum Classique {
        static let bleu = Color(clair: 0x3F74D9, sombre: 0x5B8DEF)
        static let encre = Color(clair: 0x1E2B45, sombre: 0xE8EFFC)
        static let fondHaut = Color(clair: 0xFFFFFF, sombre: 0x0B0F1A)
        static let fondBas = Color(clair: 0xDCE9FB, sombre: 0x13203A)
        static let carte = Color(clair: 0xFFFFFF, sombre: 0x1A2438)
        static let ombre = Color(clair: 0x3F74D9, sombre: 0x000000).opacity(0.10)
    }
}

public enum EgidePalette: String, CaseIterable, Identifiable, Sendable {
    case classique
    case nightCity

    public var id: Self { self }

    public var nom: String {
        switch self {
        case .classique: "Classique"
        case .nightCity: "Night City"
        }
    }
}

/// The chosen palette. Views that read an `EgideTheme` color redraw when it changes.
/// On the Mac the value lives in a defaults domain shared by all the suite's apps (none is sandboxed).
@Observable
public final class EgideApparence: @unchecked Sendable {
    public static let shared = EgideApparence()

    public var palette: EgidePalette {
        didSet {
            guard palette != Self.enregistree else { return }
            Self.defaults.set(palette.rawValue, forKey: Self.cle)
            #if os(macOS)
            DistributedNotificationCenter.default().postNotificationName(Self.changement, object: nil,
                                                                         deliverImmediately: true)
            #endif
        }
    }

    private static let cle = "egide.palette"
    private static var enregistree: EgidePalette {
        defaults.string(forKey: cle).flatMap(EgidePalette.init(rawValue:)) ?? .classique
    }
    #if os(macOS)
    nonisolated(unsafe) private static let defaults = UserDefaults(suiteName: "com.spoooke.egide.apparence") ?? .standard
    /// Lets the suite's other open apps switch at the same time.
    private static let changement = Notification.Name("com.spoooke.egide.palette")
    #else
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    #endif

    private init() {
        palette = Self.enregistree
        #if os(macOS)
        DistributedNotificationCenter.default().addObserver(forName: Self.changement, object: nil, queue: .main) { _ in
            Self.defaults.synchronize()
            EgideApparence.shared.palette = Self.enregistree
        }
        #endif
    }
}

/// Rectangle with its top-left and bottom-right corners cut at 45°.
public struct CoinsCoupes: InsettableShape {
    public var taille: CGFloat
    private var retrait: CGFloat = 0

    public init(taille: CGFloat) { self.taille = taille }

    public func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: retrait, dy: retrait)
        let c = max(0, min(taille - retrait, r.width / 2, r.height / 2))
        var p = Path()
        p.move(to: CGPoint(x: r.minX + c, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        p.closeSubpath()
        return p
    }

    public func inset(by amount: CGFloat) -> CoinsCoupes {
        var copie = self
        copie.retrait += amount
        return copie
    }
}

public extension View {
    /// To put on each window's root: Night City is always dark.
    func egideApparence() -> some View {
        modifier(Apparence())
    }
}

private struct Apparence: ViewModifier {
    func body(content: Content) -> some View {
        content.preferredColorScheme(EgideTheme.palette == .nightCity ? .dark : nil)
    }
}

public extension Color {
    /// Couleur qui suit le mode clair ou sombre (valeurs RVB hexadécimales).
    init(clair: UInt32, sombre: UInt32) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: sombre) : UIColor(hex: clair) })
        #else
        self.init(nsColor: NSColor(name: nil) { apparence in
            apparence.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: sombre) : NSColor(hex: clair)
        })
        #endif
    }

    /// Same color in light and dark mode.
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

#if canImport(UIKit)
import UIKit
private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#else
import AppKit
private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif

/// Palette picker, for the settings of each app.
public struct EgideChoixPalette: View {
    @Bindable private var apparence = EgideApparence.shared

    public init() {}

    public var body: some View {
        Picker("Thème", selection: $apparence.palette) {
            ForEach(EgidePalette.allCases) { Text($0.nom).tag($0) }
        }
    }
}

public extension View {
    /// For a menu bar panel: its window ignores `preferredColorScheme` and keeps the system's light material,
    /// so Night City paints its own dark background there.
    func egideMenuBar() -> some View {
        modifier(PanneauBarre())
    }
}

private struct PanneauBarre: ViewModifier {
    func body(content: Content) -> some View {
        if EgideTheme.palette == .nightCity {
            content
                .environment(\.colorScheme, .dark)
                .background {
                    LinearGradient(colors: [EgideTheme.fondHaut, EgideTheme.fondBas], startPoint: .top, endPoint: .bottom)
                        .overlay(alignment: .top) { EgideTheme.contour.frame(height: 1) }
                        .ignoresSafeArea()
                }
        } else {
            content
        }
    }
}

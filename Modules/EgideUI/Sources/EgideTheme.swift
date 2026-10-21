import SwiftUI

/// Charte d'Égide, tirée de la famille d'icônes : fond blanc → bleu pâle, trait bleu, coins arrondis, ombres légères.
/// Chaque couleur a sa variante sombre (bleu nuit, bleu plus lumineux).
public enum EgideTheme {
    /// Bleu du trait des icônes (#3F74D9) : accent, liens, boutons.
    public static let bleu = Color(clair: 0x3F74D9, sombre: 0x5B8DEF)
    /// Texte principal, bleu très foncé plutôt que noir.
    public static let encre = Color(clair: 0x1E2B45, sombre: 0xE8EFFC)
    /// Haut et bas du fond dégradé (#FFFFFF → #DCE9FB).
    public static let fondHaut = Color(clair: 0xFFFFFF, sombre: 0x0B0F1A)
    public static let fondBas = Color(clair: 0xDCE9FB, sombre: 0x13203A)
    /// Cartes posées sur le fond.
    public static let carte = Color(clair: 0xFFFFFF, sombre: 0x1A2438)
    /// Contour fin des cartes et des icônes.
    public static let contour = bleu.opacity(0.10)
    /// Ombre bleutée, très légère.
    public static let ombre = Color(clair: 0x3F74D9, sombre: 0x000000).opacity(0.10)

    public static let rayonCarte: CGFloat = 18
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

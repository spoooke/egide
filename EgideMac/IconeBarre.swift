import AppKit

/// Icône d'Égide dans la barre des menus : le bouclier de l'app, plein, avec la grille des outils en creux
/// (3 × 2 points), comme sur l'icône. Image « modèle » : macOS la teinte selon le thème de la barre.
enum IconeBarre {
    static let image: NSImage = {
        let taille = NSSize(width: 16, height: 18)
        let image = NSImage(size: taille, flipped: true) { _ in
            let bouclier = NSBezierPath()
            bouclier.move(to: NSPoint(x: 8, y: 0.5))
            bouclier.curve(to: NSPoint(x: 15.5, y: 3), controlPoint1: NSPoint(x: 10.5, y: 2), controlPoint2: NSPoint(x: 13, y: 2.6))
            bouclier.line(to: NSPoint(x: 15.5, y: 8.5))
            bouclier.curve(to: NSPoint(x: 8, y: 17.5), controlPoint1: NSPoint(x: 15.5, y: 13), controlPoint2: NSPoint(x: 12, y: 16))
            bouclier.curve(to: NSPoint(x: 0.5, y: 8.5), controlPoint1: NSPoint(x: 4, y: 16), controlPoint2: NSPoint(x: 0.5, y: 13))
            bouclier.line(to: NSPoint(x: 0.5, y: 3))
            bouclier.curve(to: NSPoint(x: 8, y: 0.5), controlPoint1: NSPoint(x: 3, y: 2.6), controlPoint2: NSPoint(x: 5.5, y: 2))
            bouclier.close()
            // Les points de la grille sont percés dans le bouclier (règle pair-impair).
            for ligne in 0..<2 {
                for colonne in 0..<3 {
                    let centre = NSPoint(x: 4.5 + Double(colonne) * 3.5, y: 6.5 + Double(ligne) * 3.5)
                    bouclier.appendOval(in: NSRect(x: centre.x - 1.1, y: centre.y - 1.1, width: 2.2, height: 2.2))
                }
            }
            bouclier.windingRule = .evenOdd
            NSColor.black.setFill()
            bouclier.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Égide"
        return image
    }()
}

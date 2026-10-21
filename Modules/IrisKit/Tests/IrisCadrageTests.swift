import CoreGraphics
import Foundation
import Testing
@testable import IrisKit

/// Photos fabriquées par les tests : une feuille claire posée en biais sur une table sombre.
struct IrisCadrageTests {
    static let largeur = 1200, hauteur = 1600

    /// Coins de la feuille (normalisés, origine en haut à gauche) : un rectangle de 600 × 900 px tourné de 12°.
    static let feuille: IrisCoins = {
        let centre = CGPoint(x: 600, y: 800), angle = 12 * Double.pi / 180
        let demi = [(-300.0, -450.0), (300.0, -450.0), (300.0, 450.0), (-300.0, 450.0)]
        let p = demi.map { dx, dy in
            CGPoint(x: (centre.x + dx * cos(angle) - dy * sin(angle)) / Double(largeur),
                    y: (centre.y + dx * sin(angle) + dy * cos(angle)) / Double(hauteur))
        }
        return IrisCoins(p[0], p[1], p[2], p[3])
    }()

    /// La photo : fond sombre, feuille claire, quelques bandes grises en guise de lignes de texte.
    static func photo() -> CGImage {
        let contexte = CGContext(data: nil, width: largeur, height: hauteur, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        contexte.setFillColor(CGColor(red: 0.12, green: 0.1, blue: 0.09, alpha: 1))
        contexte.fill(CGRect(x: 0, y: 0, width: largeur, height: hauteur))
        // CGContext : origine en bas à gauche.
        let points = feuille.points.map { CGPoint(x: $0.x * Double(largeur), y: (1 - $0.y) * Double(hauteur)) }
        contexte.setFillColor(CGColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1))
        contexte.addLines(between: points)
        contexte.closePath()
        contexte.fillPath()
        contexte.setFillColor(CGColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1))
        for ligne in 0..<8 {
            let t = 0.2 + Double(ligne) * 0.08
            let gauche = interpoler(points[0], points[3], t), droite = interpoler(points[1], points[2], t)
            let bas = interpoler(points[0], points[3], t + 0.025), basDroite = interpoler(points[1], points[2], t + 0.025)
            contexte.addLines(between: [interpoler(gauche, droite, 0.1), interpoler(gauche, droite, 0.8),
                                        interpoler(bas, basDroite, 0.8), interpoler(bas, basDroite, 0.1)])
            contexte.closePath()
            contexte.fillPath()
        }
        return contexte.makeImage()!
    }

    private static func interpoler(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// Luminosité moyenne (0…1) d'une image, mesurée sur une version réduite.
    static func luminosite(_ image: CGImage, zone: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> Double {
        let cote = 64
        let contexte = CGContext(data: nil, width: cote, height: cote, bitsPerComponent: 8, bytesPerRow: cote,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        contexte.draw(image, in: CGRect(x: 0, y: 0, width: cote, height: cote))
        let octets = contexte.data!.assumingMemoryBound(to: UInt8.self)
        var somme = 0.0, nombre = 0
        // Mémoire du contexte : première rangée en haut de l'image.
        for y in Int(zone.minY * Double(cote))..<Int(zone.maxY * Double(cote)) {
            for x in Int(zone.minX * Double(cote))..<Int(zone.maxX * Double(cote)) {
                somme += Double(octets[y * cote + x]) / 255
                nombre += 1
            }
        }
        return somme / Double(nombre)
    }

    @Test func coinsValides() {
        #expect(IrisCoins.entier.valide)
        #expect(Self.feuille.valide)
        // Coins croisés (haut droite et bas droite échangés) : refusé.
        let p = Self.feuille.points
        #expect(!IrisCoins(p[0], p[2], p[1], p[3]).valide)
        // Sens inverse : refusé.
        #expect(!IrisCoins(p[0], p[3], p[2], p[1]).valide)
        // Trop petit : refusé.
        #expect(!IrisCoins(CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.6, y: 0.5), CGPoint(x: 0.6, y: 0.6), CGPoint(x: 0.5, y: 0.6)).valide)
    }

    @Test func imageEntiereInchangee() throws {
        let photo = Self.photo()
        let image = try IrisCadrage.redresser(photo, coins: .entier)
        #expect(image.width == photo.width && image.height == photo.height)
    }

    /// Les coins de la feuille → une image droite, aux proportions de la feuille, claire jusqu'aux bords.
    @Test func redressement() throws {
        let photo = Self.photo()
        #expect(Self.luminosite(photo) < 0.6)
        let image = try IrisCadrage.redresser(photo, coins: Self.feuille)
        #expect(abs(Double(image.width) - 600) < 30)
        #expect(abs(Double(image.height) - 900) < 30)
        // Plus de table sombre : les coins de l'image redressée sont clairs.
        for zone in [CGRect(x: 0, y: 0, width: 0.1, height: 0.1), CGRect(x: 0.9, y: 0, width: 0.1, height: 0.1),
                     CGRect(x: 0, y: 0.9, width: 0.1, height: 0.1), CGRect(x: 0.9, y: 0.9, width: 0.1, height: 0.1)] {
            #expect(Self.luminosite(image, zone: zone) > 0.85)
        }
        // Les lignes grises sont redevenues horizontales : une bande sans ligne reste claire d'un bout à l'autre.
        #expect(Self.luminosite(image, zone: CGRect(x: 0.05, y: 0.04, width: 0.9, height: 0.1)) > 0.9)
    }

    @Test func coinsInvalidesRefuses() {
        let p = Self.feuille.points
        #expect(throws: IrisErreur.self) { try IrisCadrage.redresser(Self.photo(), coins: IrisCoins(p[0], p[2], p[1], p[3])) }
    }

    /// Vision trouve la feuille sur l'iPhone, à quelques pour cent près.
    @Test func detection() async throws {
        let coins = try #require(await IrisCadrage.detecter(Self.photo()))
        for (trouve, attendu) in zip(coins.points, Self.feuille.points) {
            #expect(abs(trouve.x - attendu.x) < 0.04, "x : \(trouve) au lieu de \(attendu)")
            #expect(abs(trouve.y - attendu.y) < 0.04, "y : \(trouve) au lieu de \(attendu)")
        }
        // Redressée avec les coins trouvés : une feuille claire.
        let image = try IrisCadrage.redresser(Self.photo(), coins: coins)
        #expect(Self.luminosite(image) > 0.8)
    }
}

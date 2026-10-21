import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

/// Les 4 coins d'un document sur une image, en coordonnées normalisées (0…1, origine en haut à gauche, comme à l'écran).
/// Ordre : haut gauche, haut droite, bas droite, bas gauche.
public struct IrisCoins: Equatable, Sendable {
    public var points: [CGPoint]

    public init(_ hautGauche: CGPoint, _ hautDroite: CGPoint, _ basDroite: CGPoint, _ basGauche: CGPoint) {
        points = [hautGauche, hautDroite, basDroite, basGauche]
    }

    /// L'image entière, sans recadrage.
    public static let entier = IrisCoins(CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1))

    /// Quadrilatère utilisable : convexe, coins dans le bon ordre, assez grand (2 % de l'image au moins).
    public var valide: Bool {
        guard points.count == 4 else { return false }
        var signe = 0.0, aire = 0.0
        for i in 0..<4 {
            let a = points[i], b = points[(i + 1) % 4], c = points[(i + 2) % 4]
            let croix = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if croix == 0 || (signe != 0 && (croix > 0) != (signe > 0)) { return false }
            signe = croix
            aire += a.x * b.y - b.x * a.y
        }
        // Sens horaire à l'écran (y vers le bas) : produits vectoriels positifs.
        return signe > 0 && abs(aire) / 2 >= 0.02
    }
}

/// Photo importée : bords du document détectés sur l'iPhone, image redressée comme au scanner.
public enum IrisCadrage {
    /// Coins du document trouvés par Vision sur l'iPhone, ou nil si aucun document n'est vu.
    /// D'abord la détection de documents ; à défaut (rien vu, ou simulateur), le plus grand rectangle.
    public static func detecter(_ image: CGImage) async -> IrisCoins? {
        if let document = try? await DetectDocumentSegmentationRequest().perform(on: image),
           let coins = coins(document), coins.valide {
            return coins
        }
        var rectangles = DetectRectanglesRequest()
        rectangles.maximumObservations = 1
        rectangles.minimumAspectRatio = 0.2
        rectangles.minimumSize = 0.2
        rectangles.quadratureToleranceDegrees = 25
        guard let rectangle = try? await rectangles.perform(on: image).first, let coins = coins(rectangle), coins.valide else {
            return nil
        }
        return coins
    }

    /// Vision : origine en bas à gauche.
    private static func coins(_ quadrilatere: some QuadrilateralProviding) -> IrisCoins? {
        func point(_ p: NormalizedPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }
        return IrisCoins(point(quadrilatere.topLeft), point(quadrilatere.topRight),
                         point(quadrilatere.bottomRight), point(quadrilatere.bottomLeft))
    }

    /// Image redressée : le quadrilatère des coins devient un rectangle (Core Image, sur l'iPhone).
    public static func redresser(_ image: CGImage, coins: IrisCoins) throws -> CGImage {
        guard coins != .entier else { return image }
        guard coins.valide else { throw IrisErreur.imageIllisible }
        let largeur = Double(image.width), hauteur = Double(image.height)
        // Core Image : pixels, origine en bas à gauche.
        func pixel(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * largeur, y: (1 - p.y) * hauteur) }
        let filtre = CIFilter.perspectiveCorrection()
        filtre.inputImage = CIImage(cgImage: image)
        filtre.topLeft = pixel(coins.points[0])
        filtre.topRight = pixel(coins.points[1])
        filtre.bottomRight = pixel(coins.points[2])
        filtre.bottomLeft = pixel(coins.points[3])
        guard let sortie = filtre.outputImage, !sortie.extent.isInfinite, !sortie.extent.isEmpty,
              let redressee = CIContext().createCGImage(sortie, from: sortie.extent.integral) else {
            throw IrisErreur.imageIllisible
        }
        return redressee
    }
}

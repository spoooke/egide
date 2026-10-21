import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Préparation des images avec ImageIO (identique sur iPhone et Mac).
enum ImageProcessing {
    /// Côté le plus long gardé : assez pour lire le texte d'une capture, sans remplir iCloud.
    static let maxPixelSize = 2048

    /// Redimensionne et compresse en JPEG. `nil` si les données ne sont pas une image.
    static func prepare(_ data: Data, maxPixelSize: Int = maxPixelSize, quality: Double = 0.8) -> Data? {
        guard let image = downsampled(data, maxPixelSize: maxPixelSize) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Image réduite pour l'affichage (miniatures) sans décoder l'image entière.
    static func downsampled(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // respecte l'orientation des photos
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

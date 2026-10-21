import Foundation
import Photos

/// Photothèque où Iris dépose une copie des pages : la vraie (ajout seul), ou un double dans les tests.
public protocol IrisPhototheque: Sendable {
    /// Ajoute chaque page comme une photo ; false si l'accès est refusé.
    func ajouter(_ jpegs: [Data]) async -> Bool
}

/// Copie des pages dans Photos, seulement si le réglage « Garder le scan dans Photos » est actif.
public enum IrisCopiePhotos {
    /// Pages ajoutées à `phototheque` si `reglages.garderDansPhotos` ; sinon rien n'y va. Renvoie true si copiées.
    @discardableResult
    public static func copier(_ pages: [IrisPage], reglages: IrisReglages,
                              dans phototheque: any IrisPhototheque = IrisPhotosSysteme()) async -> Bool {
        guard reglages.garderDansPhotos, !pages.isEmpty else { return false }
        return await phototheque.ajouter(pages.map(\.jpeg))
    }
}

/// Photos d'iOS, en ajout seul : Iris ne voit pas la photothèque. Les JPEG viennent d'`IrisImage.jpeg`,
/// refaits à partir de l'image seule : ni lieu ni autre métadonnée de la photo d'origine.
public struct IrisPhotosSysteme: IrisPhototheque {
    public init() {}

    public static var refuse: Bool {
        [.denied, .restricted].contains(PHPhotoLibrary.authorizationStatus(for: .addOnly))
    }

    public func ajouter(_ jpegs: [Data]) async -> Bool {
        guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for jpeg in jpegs {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: jpeg, options: nil)
                }
            }
            return true
        } catch {
            return false
        }
    }
}

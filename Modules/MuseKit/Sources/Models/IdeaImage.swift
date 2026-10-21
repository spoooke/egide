import Foundation
import SwiftData

/// Capture d'écran ou photo jointe à une idée.
@Model
final class IdeaImage {
    /// Identifiant partagé entre appareils : nom du fichier `images/<id>.jpg` dans le dossier de synchro.
    var imageID: String = ""
    var order: Int = 0
    var createdAt: Date = Date.now
    /// JPEG allégé. `nil` tant que l'image venue d'un autre appareil n'est pas téléchargée.
    @Attribute(.externalStorage) var data: Data?
    /// Déjà déposée dans le dossier de synchro (propre à cet appareil).
    var isUploaded: Bool = false
    var idea: Idea?

    init(imageID: String = UUID().uuidString, order: Int, data: Data?) {
        self.imageID = imageID
        self.order = order
        self.data = data
    }
}

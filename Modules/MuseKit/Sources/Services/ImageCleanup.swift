import Foundation

/// Repère les fichiers `images/<id>.jpg` que plus aucune idée n'utilise.
enum ImageCleanup {
    /// Délai de grâce : une image toute neuve peut ne pas encore figurer dans le fichier
    /// de l'appareil qui l'a ajoutée (iCloud n'a pas fini de le transmettre).
    static let gracePeriod: TimeInterval = 48 * 3600

    /// Noms de fichiers à supprimer parmi `files` (nom, date de modification).
    static func orphans(files: [(name: String, modified: Date)], referenced: Set<String>, now: Date = .now) -> [String] {
        files.filter { file in
            guard file.name.hasSuffix(".jpg") else { return false }
            let imageID = String(file.name.dropLast(".jpg".count))
            return !referenced.contains(imageID) && now.timeIntervalSince(file.modified) > gracePeriod
        }
        .map(\.name)
    }
}

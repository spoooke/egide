import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Fichier de sauvegarde : même format qu'un fichier de synchro, sans les suppressions.
struct BackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
enum Backup {
    /// Toutes les idées (texte, état, tags, priorité, dates). Les images ne sont pas incluses.
    static func export(from context: ModelContext, now: Date = .now) throws -> BackupDocument {
        var file = try IdeaSync.snapshot(of: context, deviceID: "sauvegarde", deviceName: "Sauvegarde", now: now)
        file.tombstones = [] // une sauvegarde ne doit jamais supprimer d'idée à la restauration
        return BackupDocument(data: try file.encoded())
    }

    static func defaultFileName(now: Date = .now) -> String {
        "Muse-sauvegarde-\(now.formatted(.iso8601.year().month().day()))"
    }

    /// Restaure une sauvegarde : ajoute les idées absentes, ne remplace que par plus récent.
    /// Retourne le nombre d'idées ajoutées ou mises à jour.
    @discardableResult
    static func restore(_ data: Data, into context: ModelContext) throws -> Int {
        var file = try SyncFile.decode(data)
        file.tombstones = []
        let changes = try IdeaSync.merge([file], into: context)
        try context.save()
        return changes
    }
}

import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Sauvegarde de tous les modules dans un seul fichier JSON :
/// réglages d'Égide + données de chaque module qui en a (aucun secret : ni jeton, ni clé).
struct GlobalBackup: Codable, Equatable {
    var version = 1
    var createdAt: Date
    /// Ordre et visibilité des onglets (TabLayout.storage).
    var tabLayout: String
    /// Données propres à chaque module, au format du module (clé : Module.rawValue).
    var modules: [String: Data]

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> GlobalBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(GlobalBackup.self, from: data)
        guard backup.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return backup
    }

    @MainActor
    static func make(layout: TabLayout, now: Date = .now) throws -> GlobalBackup {
        var modules: [String: Data] = [:]
        for module in Module.allCases {
            if let data = try module.backup() { modules[module.rawValue] = data }
        }
        return GlobalBackup(createdAt: now, tabLayout: layout.storage, modules: modules)
    }

    /// Restaure chaque module présent (les modules inconnus de cette version sont ignorés).
    /// Renvoie un compte rendu par module, par exemple « Muse : 3 idée(s) restaurée(s) ».
    @MainActor
    func restore(into layout: inout TabLayout) -> [String] {
        layout = TabLayout(storage: tabLayout)
        var report = ["Onglets : ordre restauré"]
        for module in Module.allCases {
            guard let data = modules[module.rawValue] else { continue }
            do {
                report.append("\(module.title) : \(try module.restore(data))")
            } catch {
                report.append("\(module.title) : échec (\(error.localizedDescription))")
            }
        }
        return report
    }

    static func defaultFileName(now: Date = .now) -> String {
        "Egide-sauvegarde-\(now.formatted(.iso8601.year().month().day()))"
    }
}

/// Fichier JSON pour la fenêtre d'export.
struct GlobalBackupDocument: FileDocument {
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

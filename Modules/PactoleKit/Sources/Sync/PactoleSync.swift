import Foundation
import Observation
import SwiftData

/// Synchro de Money entre l'iPhone (Égide) et le Mac (Money), par fichiers dans un dossier iCloud Drive :
/// chaque appareil écrit `depenses-<appareil>-<id>.json` (même contenu qu'une sauvegarde, avec les suppressions)
/// et lit ceux des autres. La modification la plus récente gagne ; une suppression gagne sur une modification plus ancienne.
@Observable
@MainActor
final class PactoleSync {
    static let shared = PactoleSync()

    private(set) var folderName: String?
    private(set) var lastSyncAt: Date?
    private(set) var lastError: String?
    private(set) var isSyncing = false
    private(set) var otherDevices: [String] = []

    var isConfigured: Bool { folderBookmark != nil }

    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var pendingSync: Task<Void, Never>?
    @ObservationIgnored private var periodicSync: Task<Void, Never>?
    @ObservationIgnored private var saveObserver: NSObjectProtocol?
    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let bookmark = "money.sync.folderBookmark"
        static let folderName = "money.sync.folderName"
        static let deviceID = "money.sync.deviceID"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        folderName = defaults.string(forKey: Key.folderName)
    }

    private var folderBookmark: Data? {
        get { defaults.data(forKey: Key.bookmark) }
        set { defaults.set(newValue, forKey: Key.bookmark) }
    }

    var deviceID: String {
        if let id = defaults.string(forKey: Key.deviceID) { return id }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        defaults.set(id, forKey: Key.deviceID)
        return id
    }

    var deviceName: String {
        #if os(macOS)
        "Mac"
        #else
        "iPhone"
        #endif
    }

    var ownFileName: String { "depenses-\(deviceName.lowercased())-\(deviceID).json" }

    // MARK: - Démarrage

    func attach(_ container: ModelContainer) {
        self.container = container
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] note in
            // Seuls les enregistrements de la base de Money (les autres modules d'Égide ont la leur).
            let deMoney = (note.object as? ModelContext)?.container === container
            MainActor.assumeIsolated {
                guard deMoney else { return }
                self?.scheduleSync()
                // Bilan du dimanche toujours à jour de la dernière dépense.
                PactoleNotifications.planifierBilan(container.mainContext)
            }
        }
        periodicSync = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.sync()
            }
        }
    }

    /// Synchro différée de quelques secondes pour regrouper les modifications rapprochées.
    func scheduleSync(after delay: Duration = .seconds(2)) {
        guard isConfigured, !isSyncing else { return }
        pendingSync?.cancel()
        pendingSync = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    // MARK: - Dossier

    func chooseFolder(_ url: URL) async {
        do {
            folderBookmark = try await Task.detached { try Self.makeBookmark(for: url) }.value
            folderName = url.lastPathComponent
            defaults.set(folderName, forKey: Key.folderName)
            lastError = nil
            await sync()
        } catch {
            lastError = "Dossier inaccessible : \(error.localizedDescription)"
        }
    }

    func stopSyncing() {
        pendingSync?.cancel()
        folderBookmark = nil
        folderName = nil
        defaults.removeObject(forKey: Key.folderName)
        otherDevices = []
        lastError = nil
    }

    // MARK: - Synchro

    func sync() async {
        guard let container, let bookmark = folderBookmark, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let context = container.mainContext
        let ownFileName = ownFileName
        do {
            let (remote, freshBookmark) = try await Task.detached {
                try Self.readRemoteFiles(bookmark: bookmark, excluding: ownFileName)
            }.value
            if let freshBookmark { folderBookmark = freshBookmark }
            _ = try Self.merge(remote, into: context)
            let data = try snapshot(of: context).encoded()
            try await Task.detached { try Self.writeFile(data, named: ownFileName, bookmark: bookmark) }.value
            otherDevices = remote.compactMap(\.deviceName)
            lastSyncAt = .now
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        // L'enregistrement fait par la synchro elle-même ne doit pas en relancer une.
        pendingSync?.cancel()
    }

    /// État complet de cet appareil, avec les suppressions des 30 derniers jours.
    func snapshot(of context: ModelContext, now: Date = .now) throws -> PactoleBackup {
        var file = try PactoleBackup.make(from: context)
        file.deviceID = deviceID
        file.deviceName = deviceName
        file.plafondHebdoModifie = PactoleReglages.plafondHebdoModifie
        file.tombstones = try context.fetch(FetchDescriptor<MoneyTombstone>())
            .filter { now.timeIntervalSince($0.deletedAt) < MoneyTombstone.duree }
            .map { .init(syncID: $0.syncID, deletedAt: $0.deletedAt) }
        return file
    }

    /// Fusion de fichiers venus d'ailleurs (ou d'une sauvegarde) : suppressions d'abord, puis ajouts et modifications.
    /// Enregistre et renvoie le nombre de changements.
    @discardableResult
    static func merge(_ files: [PactoleBackup], into context: ModelContext, now: Date = .now) throws -> Int {
        var changes = 0
        var traces = Dictionary(try context.fetch(FetchDescriptor<MoneyTombstone>()).map { ($0.syncID, $0) }) { a, _ in a }
        for record in files.flatMap({ $0.tombstones ?? [] }) {
            if let trace = traces[record.syncID] {
                if record.deletedAt > trace.deletedAt { trace.deletedAt = record.deletedAt }
            } else {
                let trace = MoneyTombstone(syncID: record.syncID, deletedAt: record.deletedAt)
                context.insert(trace)
                traces[record.syncID] = trace
            }
        }
        let supprimes = traces.mapValues(\.deletedAt)
        // Éléments locaux supprimés ailleurs (une modification locale plus récente gagne).
        for depense in try context.fetch(FetchDescriptor<Depense>()) {
            if let date = supprimes[depense.syncID], date >= depense.modifiedAt { context.delete(depense); changes += 1 }
        }
        for regle in try context.fetch(FetchDescriptor<Regle>()) {
            if let date = supprimes[regle.syncID], date >= regle.modifiedAt { context.delete(regle); changes += 1 }
        }
        for frais in try context.fetch(FetchDescriptor<FraisFixe>()) {
            if let date = supprimes[frais.syncID], date >= frais.modifiedAt { context.delete(frais); changes += 1 }
        }
        for revenu in try context.fetch(FetchDescriptor<Revenu>()) {
            if let date = supprimes[revenu.syncID], date >= revenu.modifiedAt { context.delete(revenu); changes += 1 }
        }
        for virement in try context.fetch(FetchDescriptor<Virement>()) {
            if let date = supprimes[virement.syncID], date >= virement.modifiedAt { context.delete(virement); changes += 1 }
        }
        for file in files {
            changes += try file.appliquer(dans: context, supprimes: supprimes)
        }
        // Ménage des vieilles traces.
        for trace in traces.values where now.timeIntervalSince(trace.deletedAt) > MoneyTombstone.duree {
            context.delete(trace)
        }
        if context.hasChanges { try context.save() }
        return changes
    }

    // MARK: - Fichiers (hors thread principal)

    private nonisolated static func makeBookmark(for url: URL) throws -> Data {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private nonisolated static func withFolder<T>(_ bookmark: Data, _ body: (URL) throws -> T) throws -> (T, Data?) {
        var isStale = false
        let folder = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let fresh = isStale ? try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) : nil
        return (try body(folder), fresh)
    }

    nonisolated static func readRemoteFiles(in folder: URL, excluding ownFileName: String) throws -> [PactoleBackup] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).compactMap { name in
            // Fichier pas encore téléchargé depuis iCloud : « .depenses-x.json.icloud ».
            var fileName = name
            if name.hasPrefix("."), name.hasSuffix(".icloud") { fileName = String(name.dropFirst().dropLast(".icloud".count)) }
            guard fileName.hasPrefix("depenses-"), fileName.hasSuffix(".json"), fileName != ownFileName else { return nil }
            let url = folder.appending(path: fileName)
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            guard let data = try? coordinatedRead(url) else { return nil }
            return try? PactoleBackup.decode(data)
        }
    }

    private nonisolated static func readRemoteFiles(bookmark: Data, excluding ownFileName: String) throws -> ([PactoleBackup], Data?) {
        try withFolder(bookmark) { try readRemoteFiles(in: $0, excluding: ownFileName) }
    }

    private nonisolated static func writeFile(_ data: Data, named fileName: String, bookmark: Data) throws {
        _ = try withFolder(bookmark) { folder in
            let url = folder.appending(path: fileName)
            var coordinationError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
                do { try data.write(to: target, options: .atomic) } catch { writeError = error }
            }
            if let error = coordinationError ?? writeError { throw error }
        }
    }

    private nonisolated static func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            result = Result { try Data(contentsOf: target) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}

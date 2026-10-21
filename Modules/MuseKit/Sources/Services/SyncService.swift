import Foundation
import Observation
import SwiftData

/// Synchro des idées par fichiers dans un dossier iCloud Drive choisi par l'utilisateur.
/// Chaque appareil écrit `idees-<appareil>.json` et lit les fichiers des autres.
@Observable
@MainActor
final class SyncService {
    static let shared = SyncService()

    private(set) var folderName: String?
    private(set) var lastSyncAt: Date?
    private(set) var lastError: String?
    private(set) var isSyncing = false
    private(set) var otherDevices: [String] = []

    var isConfigured: Bool { folderBookmark != nil }

    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var pendingSync: Task<Void, Never>?
    @ObservationIgnored private var saveObserver: NSObjectProtocol?
    @ObservationIgnored private var periodicSync: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        // Préfixe « muse. » : les préférences d'Égide sont partagées entre les modules.
        static let bookmark = "muse.sync.folderBookmark"
        static let folderName = "muse.sync.folderName"
        static let deviceID = "muse.sync.deviceID"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        folderName = defaults.string(forKey: Key.folderName)
    }

    // MARK: - Identité de l'appareil (propre à chaque appareil, jamais synchronisée)

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
        #if os(macOS) || targetEnvironment(macCatalyst)
        "Mac"
        #else
        "iPhone"
        #endif
    }

    var ownFileName: String { "idees-\(deviceName.lowercased())-\(deviceID).json" }

    // MARK: - Démarrage

    /// Branche le service sur la base de l'app et synchronise après chaque enregistrement.
    func attach(_ container: ModelContainer) {
        self.container = container
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main
        ) { [weak self] note in
            // Seuls les enregistrements de la base de Muse (les autres modules d'Égide ont la leur).
            let fromMuse = (note.object as? ModelContext)?.container === container
            MainActor.assumeIsolated { if fromMuse { self?.scheduleSync() } }
        }
        // Récupère les changements des autres appareils toutes les minutes.
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
            let bookmark = try await Task.detached { try Self.makeBookmark(for: url) }.value
            folderBookmark = bookmark
            markAllImagesForUpload()
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
            // 1. Lire les fichiers des autres appareils.
            let (read, freshBookmark) = try await Task.detached {
                try Self.readRemoteFiles(bookmark: bookmark, excluding: ownFileName)
            }.value
            let remote = read.files
            let currentFolderName = read.folderName
            if let freshBookmark { folderBookmark = freshBookmark }
            // Le dossier a pu être renommé dans iCloud Drive : le signet le suit, on met le nom à jour.
            if currentFolderName != folderName {
                folderName = currentFolderName
                defaults.set(currentFolderName, forKey: Key.folderName)
            }

            // 2. Fusionner, puis échanger les images, puis 3. écrire l'état complet de cet appareil.
            try IdeaSync.merge(remote, into: context)
            try await transferImages(context: context, bookmark: bookmark)
            let snapshot = try IdeaSync.snapshot(of: context, deviceID: deviceID, deviceName: deviceName)
            if context.hasChanges { try context.save() }
            let data = try snapshot.encoded()
            try await Task.detached {
                try Self.writeFile(data, named: ownFileName, bookmark: bookmark)
            }.value

            // 4. Ménage des images que plus aucune idée n'utilise, seulement si tous les fichiers
            //    des autres appareils ont pu être lus (sinon une image encore utilisée pourrait partir).
            if read.allRead {
                let referenced = Set((remote + [snapshot]).flatMap(\.ideas).flatMap { $0.imageIDs ?? [] })
                _ = try? await Task.detached {
                    try Self.withFolder(bookmark) { try Self.removeOrphanImages(in: $0, referenced: referenced) }
                }.value
            }

            otherDevices = remote.map(\.deviceName)
            lastSyncAt = .now
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        // L'enregistrement fait par la synchro elle-même ne doit pas en relancer une.
        pendingSync?.cancel()
    }

    // MARK: - Images

    /// Dépose les images locales pas encore envoyées et récupère celles venues d'ailleurs.
    private func transferImages(context: ModelContext, bookmark: Data) async throws {
        let images = try context.fetch(FetchDescriptor<IdeaImage>())
        let uploads = images.filter { !$0.isUploaded }.compactMap { image in image.data.map { (image.imageID, $0) } }
        let downloads = images.filter { $0.data == nil }.map(\.imageID)
        guard !uploads.isEmpty || !downloads.isEmpty else { return }

        let ((uploaded, received), _) = try await Task.detached {
            try Self.withFolder(bookmark) { folder in
                try Self.exchangeImages(in: folder, uploads: uploads, downloads: downloads)
            }
        }.value

        for image in images {
            if uploaded.contains(image.imageID) { image.isUploaded = true }
            if let data = received[image.imageID] { image.data = data }
        }
    }

    /// Remet les images à envoyer quand le dossier de synchro change.
    private func markAllImagesForUpload() {
        guard let context = container?.mainContext,
              let images = try? context.fetch(FetchDescriptor<IdeaImage>()) else { return }
        for image in images where image.data != nil { image.isUploaded = false }
    }

    private nonisolated static func exchangeImages(
        in folder: URL, uploads: [(String, Data)], downloads: [String]
    ) throws -> (uploaded: Set<String>, received: [String: Data]) {
        let imagesFolder = folder.appending(path: "images", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)

        var uploaded = Set<String>()
        for (imageID, data) in uploads {
            let url = imagesFolder.appending(path: "\(imageID).jpg")
            var coordinationError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
                do { try data.write(to: target, options: .atomic) } catch { writeError = error }
            }
            if coordinationError == nil, writeError == nil { uploaded.insert(imageID) }
        }

        var received: [String: Data] = [:]
        for imageID in downloads {
            let url = imagesFolder.appending(path: "\(imageID).jpg")
            // Pas encore téléchargée depuis iCloud : on la demande, elle arrivera à une prochaine synchro.
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            if let data = try? coordinatedRead(url) { received[imageID] = data }
        }
        return (uploaded, received)
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

    private struct RemoteRead: Sendable {
        var files: [SyncFile]
        var folderName: String
        /// Tous les fichiers des autres appareils ont été lus (aucun en attente d'iCloud).
        var allRead: Bool
    }

    private nonisolated static func readRemoteFiles(bookmark: Data, excluding ownFileName: String) throws -> (RemoteRead, Data?) {
        try withFolder(bookmark) { folder in
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            var expected = 0
            let files = names.compactMap { name -> SyncFile? in
                // Fichier pas encore téléchargé depuis iCloud : « .idees-x.json.icloud ».
                var fileName = name
                if name.hasPrefix("."), name.hasSuffix(".icloud") {
                    fileName = String(name.dropFirst().dropLast(".icloud".count))
                }
                guard fileName.hasPrefix("idees-"), fileName.hasSuffix(".json"), fileName != ownFileName else { return nil }
                expected += 1

                let url = folder.appending(path: fileName)
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                guard let data = try? coordinatedRead(url) else { return nil }
                return try? SyncFile.decode(data)
            }
            return RemoteRead(files: files, folderName: folder.lastPathComponent, allRead: files.count == expected)
        }
    }

    private nonisolated static func removeOrphanImages(in folder: URL, referenced: Set<String>) throws {
        let imagesFolder = folder.appending(path: "images", directoryHint: .isDirectory)
        let urls = try FileManager.default.contentsOfDirectory(
            at: imagesFolder, includingPropertiesForKeys: [.contentModificationDateKey])
        let files = urls.compactMap { url -> (name: String, modified: Date)? in
            guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
            return (url.lastPathComponent, date)
        }
        for name in ImageCleanup.orphans(files: files, referenced: referenced) {
            let url = imagesFolder.appending(path: name)
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
                try? FileManager.default.removeItem(at: target)
            }
        }
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

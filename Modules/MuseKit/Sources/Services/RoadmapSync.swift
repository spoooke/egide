import Foundation
import SwiftData

enum RoadmapError: LocalizedError, Equatable {
    case noSource
    case noChecklist
    case unreadable(String)
    case itemNotFound

    var errorDescription: String? {
        switch self {
        case .noSource: "Ce projet n'est relié à aucun fichier. Réimporte la roadmap."
        case .noChecklist: "Aucune case à cocher (« - [ ] ») trouvée dans ce fichier."
        case .unreadable(let reason): "Impossible de lire le fichier : \(reason)"
        case .itemNotFound: "Cette ligne n'est plus dans le fichier. Actualise le projet."
        }
    }
}

/// Import et actualisation des projets depuis un fichier roadmap.
@MainActor
enum RoadmapSync {
    /// Importe le fichier choisi dans Fichiers. Si un projet du même nom existe, il est actualisé.
    @discardableResult
    static func importRoadmap(from url: URL, in context: ModelContext) async throws -> Project {
        let (markdown, bookmark) = try await Task.detached { try readWithBookmark(url) }.value
        let parsed = RoadmapParser.parse(markdown)
        guard parsed.itemCount > 0 else { throw RoadmapError.noChecklist }

        let name = parsed.title ?? url.deletingPathExtension().lastPathComponent
        let existing = try context.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.name == name })).first
        let project = existing ?? Project(name: name)
        if existing == nil { context.insert(project) }

        project.sourceBookmark = bookmark
        project.sourceFileName = url.lastPathComponent
        merge(parsed, into: project, context: context)
        return project
    }

    /// Relit le fichier d'origine sans le redemander.
    static func refresh(_ project: Project, context: ModelContext) async throws {
        guard let bookmark = project.sourceBookmark else { throw RoadmapError.noSource }
        let (markdown, freshBookmark) = try await Task.detached { try readFromBookmark(bookmark) }.value
        let parsed = RoadmapParser.parse(markdown)
        guard parsed.itemCount > 0 else { throw RoadmapError.noChecklist }

        if let freshBookmark { project.sourceBookmark = freshBookmark }
        merge(parsed, into: project, context: context)
    }

    /// Supprime la case du fichier roadmap lui-même, puis du projet.
    static func removeItem(_ item: RoadmapItem, from project: Project, context: ModelContext) async throws {
        guard let bookmark = project.sourceBookmark else { throw RoadmapError.noSource }
        let text = item.text
        let section = item.section
        try await Task.detached { try removeLine(text: text, section: section, bookmark: bookmark) }.value
        project.items?.removeAll { $0.persistentModelID == item.persistentModelID }
        context.delete(item)
    }

    /// Met le projet en phase avec le fichier en gardant les cases cochées sur l'iPhone.
    static func merge(_ parsed: ParsedRoadmap, into project: Project, context: ModelContext) {
        if let title = parsed.title { project.name = title }

        // Cases existantes regroupées par clé ; une case dupliquée est consommée une fois.
        var pool = Dictionary(grouping: project.items ?? []) { RoadmapParser.matchKey($0.text) }
        var kept: [RoadmapItem] = []

        for (sectionIndex, section) in parsed.sections.enumerated() {
            for (index, parsedItem) in section.items.enumerated() {
                let key = RoadmapParser.matchKey(parsedItem.text)
                let item: RoadmapItem
                if var candidates = pool[key], !candidates.isEmpty {
                    item = candidates.removeFirst()
                    pool[key] = candidates
                } else {
                    item = RoadmapItem(text: parsedItem.text, section: section.title,
                                       sectionIndex: sectionIndex, index: index, isDoneInFile: parsedItem.isDone)
                    context.insert(item)
                    item.project = project
                }
                item.text = parsedItem.text
                item.section = section.title
                item.sectionIndex = sectionIndex
                item.index = index
                item.isDoneInFile = parsedItem.isDone
                // Le fichier a rattrapé l'iPhone : la surcharge n'est plus utile.
                if item.phoneOverride == parsedItem.isDone { item.phoneOverride = nil }
                kept.append(item)
            }
        }

        // Cases retirées du fichier.
        for leftover in pool.values.flatMap({ $0 }) { context.delete(leftover) }
        project.items = kept
        project.lastSyncedAt = .now
    }

    // MARK: - Lecture du fichier (hors thread principal)

    private nonisolated static func readWithBookmark(_ url: URL) throws -> (String, Data) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return (try readCoordinated(url), bookmark)
    }

    private nonisolated static func readFromBookmark(_ bookmark: Data) throws -> (String, Data?) {
        var isStale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        } catch {
            throw RoadmapError.unreadable("fichier introuvable (déplacé ou supprimé ?)")
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let fresh = isStale ? try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) : nil
        return (try readCoordinated(url), fresh)
    }

    /// Lecture, retrait de la ligne et écriture en une seule opération coordonnée.
    private nonisolated static func removeLine(text: String, section: String, bookmark: Data) throws {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            throw RoadmapError.unreadable("fichier introuvable (déplacé ou supprimé ?)")
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        var coordinationError: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { target in
            do {
                let markdown = try String(contentsOf: target, encoding: .utf8)
                guard let updated = RoadmapParser.removingItem(text: text, section: section, from: markdown) else {
                    throw RoadmapError.itemNotFound
                }
                try updated.write(to: target, atomically: true, encoding: .utf8)
            } catch {
                failure = error
            }
        }
        if let coordinationError { throw RoadmapError.unreadable(coordinationError.localizedDescription) }
        if let roadmapError = failure as? RoadmapError { throw roadmapError }
        if let failure { throw RoadmapError.unreadable(failure.localizedDescription) }
    }

    /// Lecture coordonnée : télécharge le fichier depuis iCloud Drive si besoin.
    private nonisolated static func readCoordinated(_ url: URL) throws -> String {
        var coordinationError: NSError?
        var result: Result<String, Error> = .failure(RoadmapError.unreadable("lecture interrompue"))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result { try String(contentsOf: readURL, encoding: .utf8) }
        }
        if let coordinationError { throw RoadmapError.unreadable(coordinationError.localizedDescription) }
        do {
            return try result.get()
        } catch let error as RoadmapError {
            throw error
        } catch {
            throw RoadmapError.unreadable(error.localizedDescription)
        }
    }
}

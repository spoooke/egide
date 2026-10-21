import Foundation
import SwiftData

/// Opérations sur les idées, isolées des vues pour pouvoir être testées.
@MainActor
enum IdeaActions {
    /// Remplaçable dans les tests.
    static var scheduler: any ReminderScheduling = SystemReminderScheduler()

    /// Ajoute une idée en haut de la liste. `#tag`, `!!` et `!!!` dans le texte deviennent
    /// tags et priorité. Ignore une saisie sans texte.
    @discardableResult
    static func add(_ rawText: String, in context: ModelContext) -> Idea? {
        let parsed = CaptureParser.parse(rawText)
        let text = parsed.text
        guard !text.isEmpty else { return nil }

        var descriptor = FetchDescriptor<Idea>(sortBy: [SortDescriptor(\.sortIndex)])
        descriptor.fetchLimit = 1
        let topIndex = (try? context.fetch(descriptor).first?.sortIndex) ?? 0

        let idea = Idea(text: text, sortIndex: topIndex - 1)
        idea.tags = parsed.tags
        idea.priorityLevel = parsed.priority
        context.insert(idea)
        return idea
    }

    static func setPriority(_ priority: Priority, for idea: Idea) {
        guard idea.priorityLevel != priority else { return }
        idea.priorityLevel = priority
        idea.touch()
    }

    static func addTag(_ raw: String, to idea: Idea) {
        guard let tag = Tags.normalized(raw), !Tags.contains(idea.tags, tag) else { return }
        idea.tags.append(tag)
        idea.touch()
    }

    static func removeTag(_ tag: String, from idea: Idea) {
        idea.tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        idea.touch()
    }

    static func toggle(_ idea: Idea) {
        setDone(!idea.isDone, for: idea)
    }

    /// Une idée terminée n'a plus besoin de rappel : il est annulé.
    static func setDone(_ isDone: Bool, for idea: Idea) {
        guard idea.isDone != isDone else { return }
        idea.isDone = isDone
        idea.completedAt = isDone ? .now : nil
        idea.touch()
        if isDone { clearReminder(for: idea) }
    }

    static func delete(_ idea: Idea, in context: ModelContext) {
        clearReminder(for: idea)
        if !idea.syncID.isEmpty {
            context.insert(SyncTombstone(syncID: idea.syncID))
        }
        context.delete(idea)
    }

    /// Joint une image (capture, photo) à l'idée. Retourne `false` si ce n'est pas une image.
    @discardableResult
    static func addImage(_ rawData: Data, to idea: Idea, in context: ModelContext) -> Bool {
        guard let data = ImageProcessing.prepare(rawData) else { return false }
        let image = IdeaImage(order: (idea.sortedImages.last?.order ?? -1) + 1, data: data)
        context.insert(image)
        image.idea = idea
        idea.touch()
        return true
    }

    static func removeImage(_ image: IdeaImage, from idea: Idea, in context: ModelContext) {
        idea.images?.removeAll { $0.persistentModelID == image.persistentModelID }
        context.delete(image)
        idea.touch()
    }

    /// Réordonne `ideas` (déjà triées comme à l'écran) puis renumérote leur ordre.
    static func move(_ ideas: [Idea], from source: IndexSet, to destination: Int) {
        var reordered = ideas
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, idea) in reordered.enumerated() where idea.sortIndex != Double(index) {
            idea.sortIndex = Double(index)
            idea.touch()
        }
    }

    // MARK: - Rappels

    /// Programme (ou reprogramme) le rappel de l'idée.
    /// En cas d'échec, l'idée se retrouve sans rappel et l'erreur est propagée.
    static func setReminder(_ date: Date, kind: ReminderKind, for idea: Idea) async throws {
        guard date > .now else { throw ReminderError.dateInPast }

        let id = idea.reminderID ?? UUID()
        scheduler.cancel(id: id)
        idea.reminderID = id
        idea.reminderDate = date
        idea.reminderKind = kind

        do {
            try await scheduler.schedule(id: id, text: idea.text, date: date, kind: kind)
        } catch {
            idea.reminderDate = nil
            throw error
        }
    }

    static func clearReminder(for idea: Idea) {
        if let id = idea.reminderID { scheduler.cancel(id: id) }
        idea.reminderDate = nil
    }

    /// Heure proposée par défaut : la prochaine heure pile, au moins 30 min plus tard.
    static func defaultReminderDate(from now: Date = .now, calendar: Calendar = .current) -> Date {
        calendar.nextDate(
            after: now.addingTimeInterval(30 * 60),
            matching: DateComponents(minute: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(3600)
    }
}

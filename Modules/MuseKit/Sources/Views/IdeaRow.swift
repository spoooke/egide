import SwiftUI

struct IdeaRow: View {
    let idea: Idea
    let onToggle: () -> Void

    /// « !!! » coloré devant le texte (rien sans priorité).
    private var priorityMarks: Text {
        let level = idea.priorityLevel
        guard level != .none else { return Text("") }
        return Text(level.marks + " ").bold().foregroundStyle(idea.isDone ? .secondary : level.color)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: idea.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(idea.isDone ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(idea.isDone ? "Marquer à faire" : "Marquer terminée")

            VStack(alignment: .leading, spacing: 2) {
                (priorityMarks + Text(idea.text))
                    .strikethrough(idea.isDone)
                    .foregroundStyle(idea.isDone ? .secondary : .primary)
                    .lineLimit(3)
                if !idea.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(idea.tags, id: \.self) { TagChip(tag: $0) }
                    }
                }
                HStack(spacing: 8) {
                    Text(idea.createdAt, format: .relative(presentation: .named))
                        .foregroundStyle(.tertiary)
                    if let count = idea.images?.count, count > 0 {
                        Label("\(count)", systemImage: "photo")
                            .foregroundStyle(.secondary)
                    }
                    if idea.hasUpcomingReminder, let date = idea.reminderDate {
                        Label(date.formatted(date: .abbreviated, time: .shortened),
                              systemImage: idea.reminderKind.systemImage)
                            .foregroundStyle(.tint)
                    } else if ReminderViews.isOverdue(idea), let date = idea.reminderDate {
                        // Rappel passé, idée pas faite.
                        Label(date.formatted(date: .abbreviated, time: .shortened),
                              systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                    }
                }
                .font(.caption)
            }
        }
    }
}

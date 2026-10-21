import SwiftData
import SwiftUI

/// Pastille colorée d'un tag.
struct TagChip: View {
    let tag: String
    var isSelected = false
    var showsRemove = false
    /// Suggestion à ajouter : « + tag », dans la couleur du tag.
    var isSuggestion = false

    var body: some View {
        HStack(spacing: 3) {
            Text(isSuggestion ? "+ \(tag)" : tag)
            if showsRemove {
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(isSelected ? Color.white : Tags.color(for: tag))
        .background(Tags.color(for: tag).opacity(isSelected ? 1 : 0.15), in: .capsule)
    }
}

/// Rangée de tags pour filtrer la liste (un seul tag à la fois).
struct TagFilterBar: View {
    let tags: [String]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Button {
                        selection = selection == tag ? nil : tag
                    } label: {
                        TagChip(tag: tag, isSelected: selection == tag)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }
}

/// Section « Organisation » du détail : priorité et tags.
struct OrganizationSection: View {
    @Bindable var idea: Idea
    @Query private var allIdeas: [Idea]
    @State private var newTag = ""

    private var suggestions: [String] {
        Tags.all(in: allIdeas).filter { !Tags.contains(idea.tags, $0) }
    }

    var body: some View {
        Section("Organisation") {
            Picker("Priorité", selection: Binding(
                get: { idea.priorityLevel },
                set: { IdeaActions.setPriority($0, for: idea) }
            )) {
                ForEach(Priority.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            if !idea.tags.isEmpty {
                FlowTags(tags: idea.tags) { tag in
                    Button { IdeaActions.removeTag(tag, from: idea) } label: {
                        TagChip(tag: tag, showsRemove: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retirer le tag \(tag)")
                }
            }

            TextField("Ajouter un tag", text: $newTag, prompt: Text("Ajouter un tag (ex. pro)"))
                .labelsHidden()
                .autocorrectionDisabled()
                .onSubmit {
                    IdeaActions.addTag(newTag, to: idea)
                    newTag = ""
                }

            if !suggestions.isEmpty {
                FlowTags(tags: suggestions) { tag in
                    Button { IdeaActions.addTag(tag, to: idea) } label: {
                        TagChip(tag: tag, isSuggestion: true)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Tags qui passent à la ligne quand la place manque.
struct FlowTags<Content: View>: View {
    let tags: [String]
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { content($0) }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for (index, origin) in rows.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, maxX, y + rowHeight)
    }
}

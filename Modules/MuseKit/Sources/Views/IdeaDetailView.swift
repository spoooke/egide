import EgideUI
import SwiftData
import SwiftUI

struct IdeaDetailView: View {
    @Bindable var idea: Idea
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var originalText = ""
    @State private var isDeleted = false
    @State private var shownImage: IdeaImage?

    var body: some View {
        Form {
            Group {
                Section {
                    // Sans libellé et aligné à gauche : sur Mac, un formulaire place sinon le texte à droite.
                    TextField("Idée", text: $idea.text, prompt: Text("Idée"), axis: .vertical)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .lineLimit(3...)
                        .onChange(of: idea.text) { idea.touch() }
                }
                OrganizationSection(idea: idea)
                IdeaImagesSection(idea: idea, shownImage: $shownImage)
                Section {
                    Button {
                        IdeaActions.toggle(idea)
                    } label: {
                        Label(idea.isDone ? "Remettre à faire" : "Marquer comme terminée",
                              systemImage: idea.isDone ? "arrow.uturn.backward.circle" : "checkmark.circle")
                    }
                    .sensoryFeedback(.success, trigger: idea.isDone)
                }
                if !idea.isDone {
                    ReminderSection(idea: idea)
                }
                Section {
                    LabeledContent("Créée", value: idea.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if let completedAt = idea.completedAt {
                        LabeledContent("Terminée", value: completedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                Section {
                    Button("Supprimer l'idée", role: .destructive) {
                        isDeleted = true
                        IdeaActions.delete(idea, in: context)
                        dismiss()
                    }
                }
            }
            .egideRow()
        }
        .egideList()
        .formStyle(.grouped)
        .imageHandling(for: idea, shownImage: $shownImage, context: context)
        .egideTitre("Idée")
        .inlineNavigationTitle()
        .onAppear { originalText = idea.text }
        .onDisappear {
            // Le texte a changé : on reprogramme pour que le rappel affiche le nouveau texte.
            guard !isDeleted, idea.text != originalText, idea.hasUpcomingReminder,
                  let date = idea.reminderDate else { return }
            let kind = idea.reminderKind
            Task { try? await IdeaActions.setReminder(date, kind: kind, for: idea) }
        }
    }
}

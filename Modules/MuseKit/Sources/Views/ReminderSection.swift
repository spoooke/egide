import SwiftUI

/// Section « Rappel » du détail d'une idée. Aucun rappel par défaut.
struct ReminderSection: View {
    @Bindable var idea: Idea
    @State private var errorMessage: String?

    var body: some View {
        Section {
            if idea.hasUpcomingReminder, let date = idea.reminderDate {
                if ReminderKind.available.count > 1 {
                    Picker("Type", selection: Binding(
                        get: { idea.reminderKind },
                        set: { apply(date: date, kind: $0) }
                    )) {
                        ForEach(ReminderKind.available) { kind in
                            Label(kind.label, systemImage: kind.systemImage).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                DatePicker(
                    "Quand",
                    selection: Binding(
                        get: { date },
                        set: { apply(date: $0, kind: idea.reminderKind) }
                    ),
                    in: Date.now...,
                    displayedComponents: [.date, .hourAndMinute]
                )

                presetButtons

                Button("Supprimer le rappel", role: .destructive) {
                    errorMessage = nil
                    IdeaActions.clearReminder(for: idea)
                }
            } else {
                presetButtons

                Button {
                    apply(date: IdeaActions.defaultReminderDate(), kind: idea.reminderKind)
                } label: {
                    Label("Choisir une heure…", systemImage: "bell.badge")
                }
            }
        } header: {
            Text("Rappel")
        } footer: {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else if idea.hasUpcomingReminder {
                Text(idea.reminderKind == .alarm
                     ? "L'alarme sonnera même en mode silencieux, comme un réveil."
                     : "Une notification s'affichera à l'heure choisie.")
            }
        }
    }

    /// Style `.bordered` obligatoire : dans un Form, des boutons sans style
    /// sur une même ligne se déclencheraient tous ensemble.
    private var presetButtons: some View {
        HStack(spacing: 8) {
            ForEach(ReminderPreset.allCases) { preset in
                if let date = preset.date() {
                    Button(preset.label) {
                        apply(date: date, kind: idea.reminderKind)
                    }
                    .buttonStyle(.bordered)
                    .font(.subheadline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func apply(date: Date, kind: ReminderKind) {
        errorMessage = nil
        Task {
            do {
                try await IdeaActions.setReminder(date, kind: kind, for: idea)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

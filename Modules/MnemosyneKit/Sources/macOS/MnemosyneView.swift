import EgideUI
import SwiftUI

/// Mnemosyne's tab in Égide on the Mac: the last backup first, then the disk and what comes next, then the reminder.
public struct MnemosyneView: View {
    @Bindable var model: MnemosyneModel

    public init(model: MnemosyneModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 20) {
                    summary
                    if model.destinations.isEmpty { noDisk } else { disk }
                    HistoryList(history: model.history, schedule: model.schedule)
                        .egideCard()
                }
                .frame(maxWidth: .infinity)
                reminder
                    .frame(width: 330)
            }
            .padding(.bottom, 32)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dernière sauvegarde")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(model.lastBackup.map { Wording.since($0).capitalizedFirst } ?? "Aucune pour l'instant")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(overdue ? .orange : EgideTheme.encre)
            if let lastBackup = model.lastBackup {
                Text(lastBackup.formatted(date: .complete, time: .shortened))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !model.running, let failure = model.failure {
                Label("Échec \(Wording.since(failure.at)) : \(failure.reason)", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }
            Divider().padding(.vertical, 6)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Prochaine").font(.subheadline).foregroundStyle(.secondary)
                    Text(model.running ? "En cours" : Wording.due(model.due).capitalizedFirst).font(.title3.weight(.semibold))
                }
                Spacer()
                if model.running, let status = model.status {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(Report.Progress(phase: status.phase, percent: status.percent).text)
                            .font(.callout).monospacedDigit()
                        if status.percent >= 0 {
                            ProgressView(value: status.percent).frame(width: 160)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                } else {
                    Button("Sauvegarder maintenant", systemImage: "clock.arrow.circlepath") { model.backUpNow() }
                        .buttonStyle(.egide)
                        .disabled(!model.canBackUp)
                        .help(model.canBackUp ? "Lance Time Machine sur le disque branché" : "Branche d'abord le disque de sauvegarde")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .egideCard(padding: 22)
    }

    private var disk: some View {
        VStack(alignment: .leading, spacing: 8) {
            EgideSectionTitle("Disque")
            ForEach(model.destinations, id: \.id) { destination in
                HStack {
                    Image(systemName: destination.mountPoint == nil ? "externaldrive" : "externaldrive.fill")
                        .foregroundStyle(destination.mountPoint == nil ? Color.secondary : EgideTheme.bleu)
                    Text(destination.name).font(.body.weight(.medium))
                    if let quota = destination.quotaGB { Text("· \(quota) Go au plus").foregroundStyle(.secondary) }
                    Spacer()
                    Text(destination.mountPoint == nil ? "débranché" : "branché").foregroundStyle(.secondary)
                }
            }
            Button("Changer de disque dans Réglages Système…") { model.openTimeMachineSettings() }
                .buttonStyle(.link)
                .font(.callout)
                .padding(.top, 2)
        }
        .egideCard()
    }

    private var noDisk: some View {
        VStack(alignment: .leading, spacing: 10) {
            EgideSectionTitle("Disque")
            Text("Aucun disque n'est réglé dans Time Machine. Branche le disque externe, puis choisis-le dans Réglages Système : macOS demande le mot de passe administrateur à cette étape.")
                .fixedSize(horizontal: false, vertical: true)
            Button("Ouvrir Time Machine dans Réglages Système") { model.openTimeMachineSettings() }
                .buttonStyle(.egide)
        }
        .egideCard()
    }

    private var reminder: some View {
        VStack(alignment: .leading, spacing: 12) {
            EgideSectionTitle("Rappel")
            Picker("Fréquence", selection: $model.schedule.frequency) {
                Text("Une fois par mois").tag(Schedule.Frequency.monthly)
                Text("Chaque semaine").tag(Schedule.Frequency.weekly)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if model.schedule.frequency == .weekly {
                Picker("Jour", selection: $model.schedule.weekday) {
                    // Monday first, as on a French calendar.
                    ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { Text(Schedule.weekdayName($0).capitalizedFirst).tag($0) }
                }
            }
            Picker("Heure", selection: $model.schedule.hour) {
                ForEach(7..<23) { Text("\($0) h").tag($0) }
            }
            Text("Compté depuis la dernière sauvegarde réussie : une sauvegarde faite entre-temps repousse le rappel. Égide prévient sur ce Mac et sur l'iPhone.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.notificationsDenied {
                Text("Les notifications d'Égide sont coupées dans Réglages Système › Notifications.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .egideCard()
    }

    private var overdue: Bool { model.lastBackup != nil && model.due <= .now }
}

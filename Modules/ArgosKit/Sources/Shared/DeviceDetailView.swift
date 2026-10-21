import Charts
import EgideUI
import SwiftUI

struct DeviceDetailView: View {
    let deviceID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var device: DeviceDetail?
    @State private var error: String?
    @State private var updateError: String?
    @State private var confirmDelete = false
    @State private var accepting: Check?
    @State private var acceptReason = ""

    var body: some View {
        Group {
            if let device {
                content(device)
            } else if let error {
                ContentUnavailableView("Chargement impossible", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .egideTitre(device?.latest.hostname ?? "")
        .toolbar {
            if let d = device, !d.isManual {
                ToolbarItem(placement: .primaryAction) {
                    Button(d.isScanning ? "Actualisation…" : "Actualiser", systemImage: "arrow.clockwise") {
                        Task {
                            try? await model.client?.scan(deviceID)
                            await load()
                        }
                    }
                    .disabled(!d.online || d.isScanning)
                    .help(d.online ? "Refaire le scan maintenant" : "Ordinateur hors ligne")
                }
            }
        }
        .task(id: deviceID) {
            // Les ordinateurs sont suivis en direct ; une checklist ne change que par nos réponses.
            while !Task.isCancelled {
                await load()
                if device?.isManual == true { break }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .confirmationDialog("Retirer cet appareil ?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Retirer", role: .destructive) {
                Task {
                    try? await model.client?.deleteDevice(deviceID)
                    await model.refreshDevices()
                    dismiss()
                }
            }
        } message: {
            Text(device?.isManual == true
                 ? "Ses réponses seront perdues."
                 : "Il réapparaîtra au prochain scan si l'agent tourne encore.")
        }
        .alert("Accepter ce risque ?", isPresented: Binding(get: { accepting != nil }, set: { if !$0 { accepting = nil } })) {
            TextField("Raison (ex. matériel incompatible)", text: $acceptReason)
            Button("Accepter") {
                let reason = acceptReason.trimmingCharacters(in: .whitespacesAndNewlines)
                if let check = accepting, !reason.isEmpty { Task { await accept(check.id, reason) } }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("« \(accepting?.title ?? "") » restera compté dans le score, mais ne déclenchera plus d'alerte. Rappel dans 6 mois pour revoir la décision.")
        }
    }

    private func load() async {
        guard let client = model.client else { return }
        do {
            device = try await client.device(deviceID)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    @ViewBuilder
    private func content(_ d: DeviceDetail) -> some View {
        let r = d.latest
        let answered = r.checks.filter { $0.status != .unknown }.count
        List {
            Group {
                Section {
                    HStack(spacing: 16) {
                        ScoreRing(score: r.score, size: 76)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.osVersion).font(.headline)
                            if d.isManual {
                                Text("Checklist · \(answered)/\(r.checks.count) points vérifiés").foregroundStyle(.secondary)
                                ProgressView(value: Double(answered), total: Double(max(r.checks.count, 1)))
                            } else {
                                PresenceText(isManual: false, online: d.online, lastSeen: d.lastSeen)
                                if let at = r.collectedAt?.meaningful {
                                    Text("Dernier rapport \(ago(at))").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .font(.subheadline)
                    }
                    if let history = d.history, history.count > 1 {
                        Chart(history.suffix(50), id: \.at) {
                            LineMark(x: .value("Date", $0.at), y: .value("Score", $0.score))
                                .interpolationMethod(.monotone)
                        }
                        .chartYScale(domain: 0...100)
                        .chartXAxis(.hidden)
                        .frame(height: 70)
                    }
                }

                if let health = r.health {
                    Section("Santé") { HealthView(health: health) }
                }

                if !d.isManual && r.os != "windows" {
                    Section("Mises à jour") { updateBox(d) }
                }

                ForEach(categories(r.checks), id: \.self) { cat in
                    Section(cat) {
                        ForEach(sorted(r.checks.filter { $0.category == cat }, in: d)) { c in
                            CheckRow(check: c, manual: d.isManual, deviceOS: r.os, acceptance: d.acceptance(of: c),
                                     onAccept: { reason in
                                         if let reason {
                                             Task { await accept(c.id, reason) }
                                         } else {
                                             acceptReason = ""
                                             accepting = c
                                         }
                                     },
                                     onUnaccept: { Task { await unaccept(c.id) } }) { status in
                                await answer(c.id, status)
                            }
                        }
                    }
                }

                Section {
                    Button("Retirer cet appareil", role: .destructive) { confirmDelete = true }
                }
            }
            .egideRow()
        }
        .egideList()
    }

    private func categories(_ checks: [Check]) -> [String] {
        Array(Set(checks.map(\.category))).sorted()
    }

    /// Les problèmes d'abord ; les risques acceptés passent après ceux qui restent à traiter.
    private func sorted(_ checks: [Check], in d: DeviceDetail) -> [Check] {
        func rank(_ c: Check) -> Double { d.acceptance(of: c) != nil ? 1.5 : Double(c.status.rank) }
        return d.isManual ? checks : checks.sorted { rank($0) < rank($1) }
    }

    private func accept(_ check: String, _ reason: String) async {
        await update { try await $0.accept(device: deviceID, check: check, reason: reason) }
    }

    private func unaccept(_ check: String) async {
        await update { try await $0.unaccept(device: deviceID, check: check) }
    }

    private func update(_ change: (APIClient) async throws -> DeviceDetail) async {
        guard let client = model.client else { return }
        do {
            device = try await change(client)
            await model.refreshDevices()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func answer(_ check: String, _ status: CheckStatus) async {
        guard let client = model.client else { return }
        do {
            device = try await client.answer(device: deviceID, check: check, status: status)
            await model.refreshDevices()
        } catch {
            self.error = error.localizedDescription
        }
    }

    @ViewBuilder
    private func updateBox(_ d: DeviceDetail) -> some View {
        let checked = d.latest.updatesCheckedAt?.meaningful
        let requested = d.updateRequestedAt?.meaningful
        let searching = requested.map { req in
            (checked == nil || req > checked!) && Date().timeIntervalSince(req) < 600
        } ?? false
        VStack(alignment: .leading, spacing: 8) {
            Text(updateError ?? (searching
                ? "Recherche en cours… résultat en moins d'une minute."
                : checked.map { "Dernière recherche \(ago($0))." } ?? "Aucune recherche pour le moment."))
                .font(.subheadline)
                .foregroundStyle(updateError == nil ? Color.secondary : Color.red)
            Button {
                Task {
                    do {
                        try await model.client?.checkUpdates(deviceID)
                        updateError = nil
                        await load()
                    } catch {
                        updateError = error.localizedDescription
                    }
                }
            } label: {
                Label(searching ? "Recherche…" : "Rechercher les mises à jour", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(searching || !d.online)
        }
    }
}

struct HealthView: View {
    let health: Health

    var body: some View {
        gauge("Processeur", health.cpuPercent, load(health.cpuPercent), "\(health.cpuPercent) % · \(health.cpuCores) cœurs")
        gauge("Mémoire", health.memPercent, load(health.memPercent),
              "\(health.memPercent) % · \(gb(health.memUsed)) / \(gb(health.memTotal)) Go")
        gauge("Disque", health.diskPercent, load(health.diskPercent),
              "\(health.diskPercent) % · \(gb(health.diskFree)) Go libres sur \(gb(health.diskTotal))")
        if let b = health.battery {
            gauge("Batterie", b.percent, load(100 - b.percent),
                  "\(b.percent) % · \(b.charging ? "en charge" : b.plugged ? "sur secteur" : "sur batterie")")
            if let wear = b.healthPercent, wear > 0 {
                gauge("Santé de la batterie", wear, wear >= 80 ? .green : wear >= 70 ? .orange : .red,
                      "\(wear) % de la capacité d'origine" + (b.cycles.map { " · \($0) cycles" } ?? ""))
            }
        }
    }

    private func gauge(_ label: String, _ value: Int, _ color: Color, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline.weight(.medium))
                Spacer()
                Text(text).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: Double(min(max(value, 0), 100)), total: 100).tint(color)
        }
        .padding(.vertical, 2)
    }

    private func load(_ p: Int) -> Color { p >= 90 ? .red : p >= 70 ? .orange : .green }

    private func gb(_ bytes: UInt64) -> String {
        let v = Double(bytes) / 1e9
        return v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
    }
}

struct CheckRow: View {
    let check: Check
    let manual: Bool
    let deviceOS: String
    var acceptance: Acceptance?
    /// Raison fournie : renouvellement immédiat ; nil : demander la raison.
    var onAccept: (String?) -> Void = { _ in }
    var onUnaccept: () -> Void = {}
    let onAnswer: (CheckStatus) async -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(acceptance == nil ? check.status.label : "Risque accepté")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(acceptance == nil ? statusColor(check.status) : .gray)
                Text(check.title).font(.subheadline.weight(.medium))
                    .foregroundStyle(acceptance == nil ? .primary : .secondary)
            }
            Text("Gravité \(check.severity.label)").font(.caption).foregroundStyle(.secondary)
            if let detail = check.detail, !detail.isEmpty {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            if manual, let how = check.how, check.status != .pass {
                Text("**Où vérifier :** \(how)").font(.callout)
            }
            if let fix = check.fix, acceptance == nil, check.status == .fail || check.status == .warn {
                Text("→ \(fix)").font(.callout)
            }
            if let url = settingsURL {
                Button("Ouvrir les réglages", systemImage: "arrow.up.forward.app") { openURL(url) }
                    .font(.callout)
            }
            if let acceptance {
                Text("**Raison :** \(acceptance.reason)").font(.callout)
                Text("Accepté le \(acceptance.at.formatted(date: .long, time: .omitted)) · compte toujours dans le score")
                    .font(.caption).foregroundStyle(.secondary)
                if acceptance.isDue {
                    Text("À revoir maintenant").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                } else {
                    Text("À revoir le \(acceptance.reviewAt.formatted(date: .long, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if acceptance.isDue {
                        Button("Renouveler pour 6 mois") { onAccept(acceptance.reason) }
                    }
                    Button("Annuler l'acceptation", role: .destructive) { onUnaccept() }
                }
                .buttonStyle(.borderless)
                .font(.callout)
            } else if check.status == .fail || check.status == .warn {
                Button("Accepter ce risque…") { onAccept(nil) }
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
            if manual {
                Picker("Réponse", selection: Binding(
                    get: { check.status },
                    set: { new in Task { await onAnswer(new) } }
                )) {
                    Text("Oui").tag(CheckStatus.pass)
                    Text("Non").tag(CheckStatus.fail)
                    Text("Je ne sais pas").tag(CheckStatus.unknown)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .padding(.vertical, 4)
    }

    /// Les liens de réglages ne s'ouvrent que sur la machine où l'on clique :
    /// sur Mac pour un appareil macOS (écran exact), sur iPhone pour la checklist iOS.
    /// iOS n'ouvre que l'accueil des Réglages ; le chemin exact est dans « Où vérifier ».
    private var settingsURL: URL? {
        guard check.status != .pass, acceptance == nil else { return nil }
        #if os(macOS)
        guard !manual, deviceOS == "darwin",
              let link = check.link, link.hasPrefix("x-apple.systempreferences:") else { return nil }
        return URL(string: link)
        #else
        guard manual, deviceOS == "ios" else { return nil }
        return URL(string: "App-prefs:")
        #endif
    }
}

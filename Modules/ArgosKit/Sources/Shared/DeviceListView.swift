import EgideUI
import SwiftUI

enum Route: Hashable {
    case device(String)
    case alerts
    case network
    case events
}

struct DeviceListView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [Route] = []
    @State private var showAddPhone = false
    @Environment(\.goHome) private var goHome
    @Environment(\.egideIcone) private var icone

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                #if os(macOS)
                tableau
                #else
                liste
                #endif
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .device(let id): DeviceDetailView(deviceID: id)
                case .alerts: AlertsView()
                case .network: NetworkView()
                case .events: EventsView()
                }
            }
            .sheet(isPresented: $showAddPhone) {
                AddPhoneView { id in path.append(.device(id)) }
            }
            .onChange(of: model.requestedRoute, initial: true) { _, route in
                guard let route else { return }
                path = [route]
                model.requestedRoute = nil
            }
            .task {
                // Rafraîchissement en direct tant que l'écran est affiché.
                while !Task.isCancelled {
                    await model.refreshDevices()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }

    /// iPhone : une liste, le résumé en tête.
    private var liste: some View {
        List {
            Group {
                Section { summary }
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)

                if let error = model.listError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }

                Section {
                    NavigationLink(value: Route.network) {
                        if model.netUnapproved > 0 {
                            Label("Réseau local : \(model.netUnapproved) appareil(s) à valider", systemImage: "wifi.exclamationmark")
                                .foregroundStyle(.red)
                        } else {
                            Label("Réseau local", systemImage: "wifi")
                        }
                    }
                    NavigationLink(value: Route.events) {
                        Label("Historique", systemImage: "clock.arrow.circlepath")
                    }
                }

                Section("Appareils") {
                    if model.devices.isEmpty && model.listError == nil {
                        Text("Aucun appareil pour l'instant.").foregroundStyle(.secondary)
                    }
                    ForEach(model.devices) { d in
                        NavigationLink(value: Route.device(d.id)) { DeviceRow(device: d) }
                    }
                }
            }
            .egideRow()
        }
        .egideList()
        .navigationTitle("Argos")
        .toolbar {
            HomeToolbarItem(action: goHome)
            ToolbarItem(placement: .primaryAction) {
                Button("Actualiser", systemImage: "arrow.clockwise") { Task { await model.rescanAll() } }
                    .help("Refaire le scan de tous les ordinateurs maintenant")
            }
            ToolbarItem(placement: .primaryAction) { menuActions }
        }
        .refreshable { await model.rescanAll() }
    }

    private var menuActions: some View {
        Menu {
            Button("Ajouter un téléphone", systemImage: "iphone.badge.plus") { showAddPhone = true }
            Button("Réseau local", systemImage: "wifi") { path.append(.network) }
            Button("Historique", systemImage: "clock.arrow.circlepath") { path.append(.events) }
            Button("Alertes", systemImage: "bell") { path.append(.alerts) }
            #if os(iOS)
            Divider()
            Button("Se déconnecter", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                model.disconnect()
            }
            #endif
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
    }

    #if os(macOS)
    /// Mac : en-tête avec les actions, les appareils à gauche, l'état d'ensemble et les autres écrans à droite.
    private var tableau: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                EgideHeader("Argos", sousTitre: "Surveillance des machines", image: icone) {
                    HStack(spacing: 8) {
                        Button("Actualiser", systemImage: "arrow.clockwise") { Task { await model.rescanAll() } }
                            .help("Refaire le scan de tous les ordinateurs maintenant")
                        menuActions.fixedSize()
                    }
                    .labelStyle(.titleAndIcon)
                }
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Appareils").font(.headline)
                        if let error = model.listError {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        }
                        if model.devices.isEmpty && model.listError == nil {
                            Text("Aucun appareil pour l'instant.").foregroundStyle(.secondary)
                        }
                        ForEach(Array(model.devices.enumerated()), id: \.element.id) { rang, d in
                            if rang > 0 { Divider() }
                            Ligne(route: .device(d.id)) { DeviceRow(device: d) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .egideCard(padding: 20, cornerRadius: 24)

                    VStack(spacing: 18) {
                        etat
                        VStack(alignment: .leading, spacing: 12) {
                            Ligne(route: .network) {
                                if model.netUnapproved > 0 {
                                    Label("Réseau local : \(model.netUnapproved) à valider", systemImage: "wifi.exclamationmark")
                                        .foregroundStyle(.red)
                                } else {
                                    Label("Réseau local", systemImage: "wifi")
                                }
                            }
                            Ligne(route: .events) { Label("Historique", systemImage: "clock.arrow.circlepath") }
                            Ligne(route: .alerts) { Label("Alertes", systemImage: "bell") }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .egideCard(padding: 20, cornerRadius: 24)
                    }
                    .frame(width: 300)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 44)
            .padding(.bottom, 32)
            .frame(maxWidth: 1040, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(EgideTheme.encre)
        .egideScreen()
        .toolbar(removing: .title)
    }

    /// Score moyen dans son anneau, puis l'état en phrases plutôt qu'en tuiles de chiffres.
    private var etat: some View {
        let d = model.devices
        let moyenne = d.isEmpty ? 0 : d.reduce(0) { $0 + $1.score } / d.count
        let ordinateurs = d.filter { !$0.isManual }
        let enLigne = ordinateurs.filter(\.online).count
        let aReverifier = d.filter(\.isStale).count
        return HStack(alignment: .center, spacing: 16) {
            ScoreRing(score: moyenne, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(enLigne) ordinateur\(enLigne > 1 ? "s" : "") en ligne sur \(ordinateurs.count)")
                Text(model.totalFails == 0 ? "Rien à corriger" : "\(model.totalFails) problème\(model.totalFails > 1 ? "s" : "") à corriger")
                    .foregroundStyle(model.totalFails > 0 ? .red : .secondary)
                if aReverifier > 0 {
                    Text("\(aReverifier) à revérifier").foregroundStyle(.orange)
                }
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .egideCard(padding: 20, cornerRadius: 24)
    }
    #endif

    private var summary: some View {
        let d = model.devices
        let avg = d.isEmpty ? 0 : d.reduce(0) { $0 + $1.score } / d.count
        let computers = d.filter { !$0.isManual }
        let stale = d.filter(\.isStale).count
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
            StatTile(value: "\(avg)", label: "score moyen", color: d.isEmpty ? .primary : scoreColor(avg))
            let online = computers.filter(\.online).count
            StatTile(value: "\(online)/\(computers.count)", label: "ordinateurs en ligne",
                     color: computers.isEmpty ? .primary : online == computers.count ? .green : .orange)
            StatTile(value: "\(model.totalFails)", label: "problèmes à corriger", color: model.totalFails > 0 ? .red : .primary)
            StatTile(value: "\(stale)", label: "à revérifier", color: stale > 0 ? .orange : .primary)
        }
    }
}

struct DeviceRow: View {
    let device: DeviceSummary

    var body: some View {
        HStack(spacing: 14) {
            ScoreRing(score: device.score, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: Platform.symbol(device.os)).foregroundStyle(.secondary)
                    Text(device.hostname).font(.headline)
                }
                Text(device.osVersion.isEmpty ? Platform.name(device.os) : device.osVersion)
                    .font(.subheadline).foregroundStyle(.secondary)
                PresenceText(isManual: device.isManual, online: device.online, lastSeen: device.lastSeen)
                    .font(.caption)
                    .foregroundStyle(device.isStale ? .orange : .secondary)
                if let health = device.health {
                    Text(health.summary).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if device.fails > 0 { Pill(text: "\(device.fails) à corriger", color: .red) }
                    if device.warns > 0 { Pill(text: "\(device.warns) à surveiller", color: .orange) }
                    if device.accepted > 0 {
                        Pill(text: device.accepted > 1 ? "\(device.accepted) risques acceptés" : "1 risque accepté", color: .gray)
                    }
                    if device.isManual && device.unknowns > 0 { Pill(text: "\(device.unknowns) à vérifier", color: .gray) }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#if os(macOS)
/// Ligne qui ouvre un écran de la pile, avec un chevron à droite.
private struct Ligne<Etiquette: View>: View {
    let route: Route
    @ViewBuilder let etiquette: Etiquette

    var body: some View {
        NavigationLink(value: route) {
            HStack {
                etiquette.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif

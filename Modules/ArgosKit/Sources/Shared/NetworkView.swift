import EgideUI
import SwiftUI

// Réseau local : appareils découverts par les scans, à valider ou renommer.

struct NetDevice: Codable, Hashable, Identifiable {
    let mac: String
    let name: String?
    let ip: String
    let vendor: String?
    let hostname: String?
    let `private`: Bool?
    let approved: Bool
    let gateway: Bool?
    let scannedBy: Bool?
    let openPorts: [Int]?
    let lastSeen: Date
    let online: Bool
    let profile: DeviceProfile?
    let probeRequested: Bool?
    let probeRequestedAt: Date?

    var id: String { mac }

    var label: String {
        if let name, !name.isEmpty { return name }
        if let hostname, !hostname.isEmpty { return hostname }
        if let vendor, !vendor.isEmpty { return "Appareil \(vendor)" }
        return `private` == true ? "Téléphone ou tablette (adresse privée)" : "Appareil inconnu"
    }

    var riskyPorts: [Int] { (openPorts ?? []).filter { NetPorts.risky.contains($0) } }
}

/// Fiche d'identité issue du dernier scan approfondi : ce que l'appareil annonce de lui-même.
struct DeviceProfile: Codable, Hashable {
    struct Fact: Codable, Hashable {
        let label: String
        let value: String
    }

    struct Port: Codable, Hashable {
        let port: Int
        let name: String?
        let banner: String?
        let risky: Bool?
    }

    let at: Date
    let by: String
    let kind: String?
    let os: String?
    let facts: [Fact]?
    let ports: [Port]?

    var isEmpty: Bool { kind == nil && os == nil && (facts ?? []).isEmpty && (ports ?? []).isEmpty }
}

struct LocalNetwork: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let subnet: String
    let gatewayIp: String
    let scannedBy: String
    let lastScan: Date
    let upnp: Bool?
    let unapproved: Int
    let devices: [NetDevice]?
}

enum NetPorts {
    static let labels: [Int: String] = [
        21: "FTP", 22: "SSH", 23: "Telnet", 80: "Web", 443: "Web (HTTPS)", 445: "Partage SMB",
        554: "Caméra (RTSP)", 1883: "MQTT", 3389: "Bureau à distance", 5900: "VNC", 8080: "Web (8080)", 9100: "Imprimante",
    ]
    static let risky: Set<Int> = [21, 23, 445, 554, 1883, 3389, 5900]
}

extension APIClient {
    func networks() async throws -> [LocalNetwork] {
        try Self.decoder.decode([LocalNetwork].self, from: try await send("api/networks"))
    }

    func updateNetDevice(net: String, mac: String, name: String? = nil, approved: Bool? = nil) async throws {
        struct Body: Encodable { let name: String?; let approved: Bool? }
        try await send("api/networks/\(net)/devices/\(mac)", method: "PUT", body: Body(name: name, approved: approved))
    }

    /// Demande un scan approfondi de l'appareil : fait avec le prochain scan du réseau, lancé aussitôt.
    func requestProbe(net: String, mac: String) async throws {
        try await send("api/networks/\(net)/devices/\(mac)/probe", method: "POST")
    }

    func deleteNetDevice(net: String, mac: String) async throws {
        try await send("api/networks/\(net)/devices/\(mac)", method: "DELETE")
    }

    func renameNetwork(net: String, name: String) async throws {
        struct Body: Encodable { let name: String }
        try await send("api/networks/\(net)", method: "PUT", body: Body(name: name))
    }

    func approveAll(net: String) async throws {
        try await send("api/networks/\(net)/approve-all", method: "POST")
    }
}

struct NetworkView: View {
    @Environment(AppModel.self) private var model
    @State private var networks: [LocalNetwork]?
    @State private var selectedID: String?
    @State private var error: String?
    @State private var renaming: (net: String, device: NetDevice)?
    @State private var renamingNetwork: LocalNetwork?
    @State private var newName = ""
    @State private var scanning = false
    /// Fenêtre « patienter » : fermable sans arrêter le scan, qui continue en arrière-plan.
    @State private var showWait = false
    @State private var scanStart = Date()
    @State private var scanTask: Task<Void, Never>?
    @State private var probeTask: Task<Void, Never>?

    private var current: LocalNetwork? {
        networks?.first { $0.id == selectedID } ?? networks?.first
    }

    var body: some View {
        List {
            Group {
                if let error { Text(error).foregroundStyle(.red) }
                if let networks, networks.isEmpty {
                    Text("Aucun scan du réseau pour l'instant. Les scans ont lieu à 00:00, 12:00 et 18:00, ou avec « Actualiser ».")
                        .foregroundStyle(.secondary)
                }
                // Un onglet par réseau (maison, bureau…).
                if let networks, networks.count > 1 {
                    Section {
                        Picker("Réseau", selection: Binding(get: { current?.id }, set: { selectedID = $0 })) {
                            ForEach(networks) { n in
                                Text(n.unapproved > 0 ? "\(n.name) (\(n.unapproved))" : n.name).tag(Optional(n.id))
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .listRowBackground(Color.clear)
                }
                if let net = current {
                    Section { header(net) }
                    let devices = net.devices ?? []
                    let pending = devices.filter { !$0.approved }
                    if !pending.isEmpty {
                        Section {
                            ForEach(pending) { row($0, net: net.id) }
                            Button("Tout valider (\(pending.count))", systemImage: "checkmark.circle") {
                                Task { await act { try await $0.approveAll(net: net.id) } }
                            }
                        } header: {
                            Label("À valider", systemImage: "questionmark.circle").foregroundStyle(.red)
                        } footer: {
                            Text("Touche « Je le connais » pour chaque appareil que tu reconnais. Un inconnu qui apparaîtra ensuite déclenchera une alerte.")
                        }
                    }
                    Section {
                        ForEach(devices.filter(\.approved)) { row($0, net: net.id) }
                    } header: {
                        Label("Appareils connus", systemImage: "checkmark.shield")
                    }
                }
            }
            .egideRow()
        }
        .egideList()
        .egideTitre("Réseau local")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // Nouveau scan des réseaux (maison par le Mac, bureau par les PC).
                Button(scanning ? "Scan en cours…" : "Actualiser", systemImage: "arrow.clockwise") { startScan() }
                .disabled(scanning)
                .help("Scanner les réseaux maintenant")
            }
        }
        .overlay { if showWait { waitCard } }
        .animation(.default, value: showWait)
        .task { await load() }
        .refreshable { await load() }
        .onDisappear { scanTask?.cancel(); probeTask?.cancel() }
        .alert("Renommer l'appareil", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("ex. TV du salon", text: $newName)
            Button("Enregistrer") {
                if let r = renaming {
                    let name = newName
                    Task { await act { try await $0.updateNetDevice(net: r.net, mac: r.device.mac, name: name) } }
                }
            }
            Button("Annuler", role: .cancel) {}
        }
        .alert("Renommer le réseau", isPresented: Binding(get: { renamingNetwork != nil }, set: { if !$0 { renamingNetwork = nil } })) {
            TextField("ex. Maison, Bureau", text: $newName)
            Button("Enregistrer") {
                if let n = renamingNetwork {
                    let name = newName
                    Task { await act { try await $0.renameNetwork(net: n.id, name: name) } }
                }
            }
            Button("Annuler", role: .cancel) {}
        }
    }

    /// Réseaux dont l'ordinateur qui les surveille est en ligne : ce sont eux qu'on attend.
    private var awaited: [LocalNetwork] {
        let online = Set(model.devices.filter { $0.online && !$0.isManual }.map(\.hostname))
        return (networks ?? []).filter { online.contains($0.scannedBy) }
    }

    /// Le serveur et l'app n'ont pas forcément la même horloge à la seconde près.
    private func refreshed(_ net: LocalNetwork) -> Bool { net.lastScan > scanStart.addingTimeInterval(-5) }

    /// Nouveau scan des réseaux (maison par le Mac, bureau par les PC). La fenêtre reste
    /// affichée jusqu'à l'arrivée des résultats, 2 minutes au plus.
    private func startScan() {
        scanStart = Date()
        scanning = true
        showWait = true
        scanTask = Task {
            await model.rescanAll()
            await load()
            let deadline = scanStart.addingTimeInterval(120)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .seconds(3))
                await load()
                let nets = awaited
                // Aucun ordinateur en ligne pour scanner : rien à attendre au-delà de quelques secondes.
                if nets.isEmpty ? Date().timeIntervalSince(scanStart) > 10 : nets.allSatisfy(refreshed) { break }
            }
            scanning = false
            showWait = false
        }
    }

    private var waitCard: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Scan du réseau en cours…").font(.headline)
            if awaited.isEmpty {
                Text("Recherche des appareils connectés.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(awaited) { net in
                        Label(net.name, systemImage: refreshed(net) ? "checkmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(refreshed(net) ? Color.green : Color.secondary)
                    }
                }
                .font(.callout)
            }
            Text("Le scan peut prendre jusqu'à 2 minutes. Tu peux fermer : il continue tout seul.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Fermer") { showWait = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(maxWidth: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 20)
    }

    /// Carte d'en-tête : de quel réseau il s'agit, sa box, et l'état de ses appareils.
    private func header(_ net: LocalNetwork) -> some View {
        let devices = net.devices ?? []
        let box = devices.first { $0.gateway == true }
        let isOffice = net.name.localizedCaseInsensitiveContains("bureau") || net.name.localizedCaseInsensitiveContains("travail")
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(net.name, systemImage: isOffice ? "building.2" : "house")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Renommer", systemImage: "pencil") {
                    newName = net.name
                    renamingNetwork = net
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }
            Text("Box \(box?.vendor ?? "") · \(net.gatewayIp) · \(net.subnet)")
                .font(.callout).foregroundStyle(.secondary)
            if net.upnp == true {
                Label("UPnP actif sur la box : n'importe quel appareil du réseau peut ouvrir seul un accès depuis Internet. Désactive-le : http://\(net.gatewayIp) > Paramètres avancés > Réseau > UPnP.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
            } else if net.upnp == false {
                Label("UPnP désactivé sur la box", systemImage: "checkmark.shield").font(.callout).foregroundStyle(.green)
            }
            HStack(spacing: 10) {
                StatTile(value: "\(devices.count)", label: "appareils")
                StatTile(value: "\(devices.filter(\.online).count)", label: "présents au dernier scan", color: .green)
                StatTile(value: "\(net.unapproved)", label: "à valider", color: net.unapproved > 0 ? .red : .primary)
            }
            Text("Surveillé par \(net.scannedBy) · dernier scan \(ago(net.lastScan)) · scans à 00:00, 12:00 et 18:00")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func row(_ d: NetDevice, net: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if !d.approved {
                    Text("À valider").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                }
                Text(d.label).font(.subheadline.weight(.medium))
                if d.gateway == true { Pill(text: "box", color: .secondary) }
                if d.scannedBy == true { Pill(text: "cet ordinateur", color: .secondary) }
            }
            HStack(spacing: 5) {
                Circle().fill(d.online ? Color.green : Color.gray).frame(width: 7, height: 7)
                Text("\(d.online ? "Présent au dernier scan" : "Absent · vu \(ago(d.lastSeen))") · \(d.ip)\(d.vendor.map { $0.isEmpty || d.label.contains($0) ? "" : " · \($0)" } ?? "")")
            }
            .font(.caption).foregroundStyle(.secondary)
            if let ports = d.openPorts, !ports.isEmpty {
                Text(ports.map { NetPorts.labels[$0] ?? "port \($0)" }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(d.riskyPorts.isEmpty ? Color.secondary : Color.red)
            }
            if !d.riskyPorts.isEmpty {
                Text("→ Service sensible ouvert : désactive-le si tu ne t'en sers pas, ou change son mot de passe par défaut.")
                    .font(.caption)
            }
            if let profile = d.profile { ProfileView(profile: profile) }
            // Sur sa propre ligne : la rangée de boutons est déjà pleine sur un écran d'iPhone.
            if d.probeRequested == true {
                Label("Scan approfondi en cours…", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
            } else if d.scannedBy != true {
                Button(d.profile == nil ? "Scan approfondi" : "Refaire le scan approfondi", systemImage: "magnifyingglass") {
                    startProbe(net: net, mac: d.mac)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(!d.online)
                .help(d.online ? "Relever tout ce que l'appareil annonce de lui-même (30 secondes environ)"
                               : "Appareil absent au dernier scan")
            }
            HStack {
                if !d.approved {
                    Button("Je le connais", systemImage: "checkmark") {
                        Task { await act { try await $0.updateNetDevice(net: net, mac: d.mac, approved: true) } }
                    }
                }
                Button("Renommer", systemImage: "pencil") {
                    newName = d.name ?? ""
                    renaming = (net, d)
                }
                Spacer()
                Button("Retirer", systemImage: "trash", role: .destructive) {
                    Task { await act { try await $0.deleteNetDevice(net: net, mac: d.mac) } }
                }
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.vertical, 2)
    }

    /// Demande le scan approfondi, puis suit l'arrivée de la fiche (2 minutes au plus).
    private func startProbe(net: String, mac: String) {
        probeTask?.cancel()
        probeTask = Task {
            await act { try await $0.requestProbe(net: net, mac: mac) }
            let deadline = Date().addingTimeInterval(120)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .seconds(3))
                await load()
                let pending = networks?.first { $0.id == net }?.devices?.first { $0.mac == mac }?.probeRequested == true
                if !pending { break }
            }
        }
    }

    private func load() async {
        guard let client = model.client else { return }
        do {
            networks = try await client.networks()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func act(_ f: (APIClient) async throws -> Void) async {
        guard let client = model.client else { return }
        do { try await f(client) } catch { self.error = error.localizedDescription }
        await load()
    }
}

/// Fiche d'identité d'un appareil : type et système probables, noms annoncés, ports ouverts.
struct ProfileView: View {
    let profile: DeviceProfile
    @State private var expanded = false

    var body: some View {
        // Bouton plutôt que DisclosureGroup, qui ne se déplie pas dans une ligne de liste.
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                Label(profile.kind.map { "Fiche détaillée · \($0)" } ?? "Fiche détaillée",
                      systemImage: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
            if expanded { details }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            if profile.isEmpty {
                Text("L'appareil n'a répondu à aucune question : il est discret (téléphone, tablette) ou en veille.")
                    .foregroundStyle(.secondary)
            }
            if let os = profile.os { line("Système probable", os) }
            ForEach(profile.facts ?? [], id: \.self) { line($0.label, $0.value) }
            if let ports = profile.ports, !ports.isEmpty {
                Text("Ports ouverts").fontWeight(.semibold).padding(.top, 4)
                ForEach(ports, id: \.port) { p in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "\(p.port) · \(p.name ?? "service non identifié")")
                            .foregroundStyle(p.risky == true ? Color.red : Color.primary)
                        if let banner = p.banner, !banner.isEmpty {
                            Text(verbatim: banner).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text(verbatim: "Scan approfondi \(ago(profile.at)) par \(profile.by)").foregroundStyle(.secondary).padding(.top, 4)
        }
        .font(.caption)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Texte brut : une valeur comme « _airplay._tcp » n'est pas de la mise en forme.
    private func line(_ label: String, _ value: String) -> some View {
        var title = AttributedString(label + " : ")
        title.font = .caption.weight(.semibold)
        return Text(title + AttributedString(value))
    }
}

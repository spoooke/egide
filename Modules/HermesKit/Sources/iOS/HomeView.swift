import EgideUI
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: MacStore
    @EnvironmentObject private var client: RemoteClient
    @State private var scanning = false
    @State private var pendingPairing: PairingPayload?
    @State private var addingHostTo: PairedMac?
    @State private var newHost = ""
    @State private var showingRemote = false
    @State private var showError = false
    @Environment(\.goHome) private var goHome

    var body: some View {
        NavigationStack {
            List {
                Group {
                    if store.macs.isEmpty {
                        Section {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Aucun Mac appairé", systemImage: "desktopcomputer")
                                    .font(.headline)
                                Text("Sur le Mac, clique sur l'icône Hermès dans la barre des menus → « Appairer un iPhone… », puis scanne le code.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Button { scanning = true } label: {
                                        Label("Scanner", systemImage: "qrcode.viewfinder")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .labelStyle(.titleAndIcon)
                                    // System paste button: reads the clipboard without the "Allow Paste" prompt.
                                    PasteButton(payloadType: String.self) { strings in
                                        DispatchQueue.main.async { handlePasted(strings.first) }
                                    }
                                    .labelStyle(.titleAndIcon)
                                    .buttonBorderShape(.capsule)
                                }
                                .padding(.top, 4)
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    Section(store.macs.isEmpty ? "" : "Mes Mac") {
                        ForEach(store.macs) { mac in
                            Button { connect(mac) } label: { MacRow(mac: mac) }
                                .swipeActions {
                                    Button(role: .destructive) { store.remove(mac) } label: { Label("Oublier", systemImage: "trash") }
                                    Button { addingHostTo = mac; newHost = "" } label: { Label("Adresse", systemImage: "network") }
                                        .tint(EgideTheme.bleu)
                                }
                        }
                    }
                    Section {
                        // La clé de l'iPhone est créée au premier appairage : on redessine après chaque changement de liste.
                        SecurityFooter()
                            .id(store.macs.map(\.id))
                    }
                }
                .egideRow()
            }
            .egideList()
            .navigationTitle("Hermès")
            .toolbar {
                HomeToolbarItem(action: goHome)
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { scanning = true } label: { Label("Scanner le QR code", systemImage: "qrcode.viewfinder") }
                        PasteButton(payloadType: String.self) { strings in
                            DispatchQueue.main.async { handlePasted(strings.first) }
                        }
                    } label: { Image(systemName: "plus") }
                }
            }
            .overlay { ConnectingOverlay() }
            #if DEBUG && targetEnvironment(simulator)
            // Test hook, compiled only into simulator debug builds: `simctl launch … -hermesPairLink <url>`.
            .onAppear {
                if let link = UserDefaults.standard.string(forKey: "hermesPairLink"), let p = PairingPayload.parse(link) {
                    pendingPairing = p
                }
            }
            #endif
        }
        .sheet(isPresented: $scanning) {
            NavigationStack {
                QRScannerView { payload in
                    scanning = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { pendingPairing = payload }
                }
                .ignoresSafeArea()
                .navigationTitle("Scanner le code du Mac")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler") { scanning = false } } }
            }
        }
        .alert("Appairer « \(pendingPairing?.n ?? "") » ?", isPresented: Binding(get: { pendingPairing != nil }, set: { if !$0 { pendingPairing = nil } })) {
            Button("Appairer") { if let p = pendingPairing { pair(p) } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Vérifie que cette empreinte est identique à celle affichée sur le Mac :\n\n\(pendingPairing.map { DeviceIdentity.fingerprint(of: $0.k) } ?? "")")
        }
        .alert("Ajouter une adresse", isPresented: Binding(get: { addingHostTo != nil }, set: { if !$0 { addingHostTo = nil } })) {
            TextField("100.x.y.z ou nom-du-mac", text: $newHost)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Ajouter") { if let m = addingHostTo { store.addHost(newHost, to: m) } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Par exemple l'adresse Tailscale du Mac, pour t'y connecter hors de chez toi.")
        }
        .alert("Connexion impossible", isPresented: Binding(get: { showError }, set: { if !$0 { showError = false; client.clearError() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            if case .failed(let msg) = client.phase { Text(msg) }
        }
        .alert("Aucun lien d'appairage", isPresented: $pasteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Sur le Mac, ouvre « Appairer un iPhone… » et clique sur « Copier le lien », puis réessaie.")
        }
        .fullScreenCover(isPresented: $showingRemote) {
            RemoteScreen { showingRemote = false; client.disconnect() }
                .ignoresSafeArea()
        }
        .onChange(of: client.phase) { _, phase in
            if phase == .connected { showingRemote = true }
            if case .failed = phase {
                // Let the full-screen session close before showing why it ended.
                let wasRemote = showingRemote
                showingRemote = false
                DispatchQueue.main.asyncAfter(deadline: .now() + (wasRemote ? 0.7 : 0)) { showError = true }
            }
        }
    }

    @State private var pasteError = false

    private func handlePasted(_ text: String?) {
        if let text, let payload = PairingPayload.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            UIPasteboard.general.string = "" // don't leave the secret lying around
            pendingPairing = payload
        } else {
            pasteError = true
        }
    }

    private func connect(_ mac: PairedMac) {
        Task {
            do {
                try await client.connect(to: mac)
                await MainActor.run { store.markConnected(mac, via: client.connectedHost) }
            } catch {}
        }
    }

    private func pair(_ payload: PairingPayload) {
        let mac = PairedMac(name: payload.n, publicKey: payload.k, hosts: payload.h, port: payload.p)
        Task {
            do {
                try await client.connect(to: mac, pairingToken: payload.t)
                await MainActor.run {
                    store.upsert(mac)
                    if let saved = store.macs.first(where: { $0.publicKey == mac.publicKey }) {
                        store.markConnected(saved, via: client.connectedHost)
                    }
                }
            } catch {}
        }
    }
}

struct MacRow: View {
    let mac: PairedMac

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(mac.name).font(.headline).foregroundStyle(.primary)
                Text(mac.fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
                if let date = mac.lastConnected {
                    Text("Dernière connexion \(date.formatted(.relative(presentation: .named)))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

struct SecurityFooter: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(MacStore.identityIsHardwareBacked ? "Clé protégée par la Secure Enclave + Face ID" : "Clé logicielle (simulateur ou Face ID absent)",
                  systemImage: MacStore.identityIsHardwareBacked ? "lock.shield.fill" : "exclamationmark.shield")
                .font(.footnote)
                .foregroundStyle(MacStore.identityIsHardwareBacked ? .green : .orange)
            if let key = MacStore.identityPublicKey {
                Text("Empreinte de cet iPhone : \(DeviceIdentity.fingerprint(of: key))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text("Connexion chiffrée de bout en bout (X25519 + ChaCha20‑Poly1305), identités épinglées. Aucun serveur tiers.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct ConnectingOverlay: View {
    @EnvironmentObject private var client: RemoteClient

    var body: some View {
        if case .connecting(let step) = client.phase {
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea()
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text(step).font(.callout).multilineTextAlignment(.center)
                    Button("Annuler") { client.disconnect() }
                        .buttonStyle(.bordered)
                }
                .padding(28)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
        }
    }
}

struct RemoteScreen: UIViewControllerRepresentable {
    @EnvironmentObject private var client: RemoteClient
    var onClose: () -> Void

    func makeUIViewController(context: Context) -> RemoteViewController {
        RemoteViewController(client: client, onClose: onClose)
    }

    func updateUIViewController(_ controller: RemoteViewController, context: Context) {}
}

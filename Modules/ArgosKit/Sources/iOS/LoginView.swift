import EgideUI
import SwiftUI
import VisionKit

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var scanning = false
    @State private var server = ""
    @State private var token = ""
    @State private var error: String?
    @State private var connecting = false
    @Environment(\.goHome) private var goHome

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        VStack(spacing: 12) {
                            Image("Logo", bundle: .argos)
                                .resizable()
                                .frame(width: 96, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            Text("Argos").font(.largeTitle.bold())
                            Text("La sécurité de tes appareils, en direct.")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .listRowBackground(Color.clear)

                    Section {
                        Button {
                            scanning = true
                        } label: {
                            Label("Scanner le QR code", systemImage: "qrcode.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(connecting)
                        .listRowBackground(Color.clear)
                    } footer: {
                        Text("Sur ton Mac : icône ♥ dans la barre des menus > « Connecter un téléphone… ». Tailscale doit être activé sur cet iPhone.")
                    }

                    Section("Ou à la main") {
                        TextField("Adresse", text: $server, prompt: Text("https://mon-mac.tailnet.ts.net"))
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Jeton", text: $token)
                        // Bouton « Coller » système : pas de demande d'autorisation, iOS sait que l'utilisateur l'a touché.
                        // Accepte le jeton seul, ou le lien de connexion complet (https://…/#token=…).
                        PasteButton(payloadType: String.self) { items in
                            let text = items.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            Task { @MainActor in
                                if let c = PairingLink.parse(text) {
                                    await connect(c)
                                } else {
                                    token = text
                                }
                            }
                        }
                        Button("Se connecter") {
                            guard let url = URL(string: server.trimmingCharacters(in: .whitespaces)), url.scheme != nil else {
                                error = "Adresse invalide."
                                return
                            }
                            Task { await connect(Connection(baseURL: url, token: token.trimmingCharacters(in: .whitespaces))) }
                        }
                        .disabled(server.isEmpty || token.isEmpty || connecting)
                    }

                    if let error {
                        Section { Text(error).foregroundStyle(.red) }
                    }
                }
                .egideRow()
            }
            .egideList()
            .sheet(isPresented: $scanning) { scannerSheet }
            .toolbar { HomeToolbarItem(action: goHome) }
        }
    }

    @ViewBuilder
    private var scannerSheet: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    QRScanner { code in
                        scanning = false
                        guard let c = PairingLink.parse(code) else {
                            error = "Ce QR code n'est pas un code Argos."
                            return
                        }
                        Task { await connect(c) }
                    }
                    .ignoresSafeArea()
                } else {
                    ContentUnavailableView("Caméra indisponible", systemImage: "camera",
                                           description: Text("Autorise l'accès à la caméra dans Réglages > Égide, ou connecte-toi à la main."))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { scanning = false } }
            }
        }
    }

    private func connect(_ c: Connection) async {
        #if !DEBUG
        // Le jeton ne doit jamais circuler en clair : HTTPS (Tailscale) obligatoire.
        guard c.baseURL.scheme == "https" else {
            error = "Adresse refusée : seule une adresse https:// (Tailscale) est acceptée."
            return
        }
        #endif
        guard await AppLock.authenticate(reason: "Confirmer l'appairage avec « \(c.baseURL.host() ?? "ce serveur") »") else {
            error = "Appairage annulé."
            return
        }
        connecting = true
        defer { connecting = false }
        do {
            try await model.connect(c)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        if !vc.isScanning { try? vc.startScanning() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in items {
                guard !done, let value = code.payloadStringValue else { continue }
                done = true
                scanner.stopScanning()
                onCode(value)
            }
        }
    }
}

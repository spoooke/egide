import Foundation
import Network
import LocalAuthentication
import os

private let log = Logger(subsystem: "com.sgillio.swiftview", category: "client")

/// Connection to one Mac: discovery, Face ID, secure handshake, video + input.
final class RemoteClient: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting(String)
        case connected
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var macName = ""
    @Published private(set) var videoSize = CGSize(width: 16, height: 10)
    @Published private(set) var fps = 0
    @Published private(set) var latencyMs: Int?

    /// Where decoded video goes. Set by the remote screen before frames arrive.
    weak var videoView: VideoView? {
        didSet { videoView?.onNeedKeyframe = { [weak self] in self?.send(.requestKeyframe) } }
    }

    private(set) var connectedMac: PairedMac?
    private(set) var connectedHost: String?
    private let queue = DispatchQueue(label: "swiftview.client", qos: .userInteractive)
    private var channel: SecureChannel?
    private var receiveTask: Task<Void, Never>?
    private var pingTimer: DispatchSourceTimer?
    private var frameCount = 0
    private var connectionID = UUID()

    // MARK: Connect

    /// Connects (or pairs, when `pairingToken` is set). Throws with a user‑readable message.
    func connect(to mac: PairedMac, pairingToken: Data? = nil) async throws {
        do {
            try await performConnect(to: mac, pairingToken: pairingToken)
        } catch {
            // Every failure must leave the "connecting" state with a readable message.
            if (error as NSError).domain != "Hermes", !(error is CancellationError) {
                log.error("connect failed: \(String(describing: error))")
                throw fail("Erreur : \(error.localizedDescription)")
            }
            throw error
        }
    }

    private func performConnect(to mac: PairedMac, pairingToken: Data?) async throws {
        disconnect()
        let myID = UUID()
        connectionID = myID
        await setPhase(.connecting("Vérification Face ID…"))

        // 1. Face ID before anything touches the network.
        log.info("step: identity")
        let blob = try MacStore.identityBlob()
        log.info("step: identity ok, hardware=\(blob.first == 1)")
        let context = LAContext()
        #if targetEnvironment(simulator)
        // The simulator cannot evaluate biometric access control; real devices always require Face ID.
        #else
        context.localizedCancelTitle = "Annuler"
        let hardware = blob.first == 1
        let policy: LAPolicy = hardware ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        var laError: NSError?
        guard context.canEvaluatePolicy(policy, error: &laError) else {
            throw fail("Face ID indisponible : \(laError?.localizedDescription ?? "configure Face ID et un code")")
        }
        do {
            try await context.evaluatePolicy(policy, localizedReason: "Se connecter à \(mac.name)")
        } catch {
            throw fail("Authentification annulée")
        }
        #endif
        log.info("step: restore")
        let identity = try DeviceIdentity.restore(from: blob, context: context)
        log.info("step: restored")

        // 2. Find the Mac: Bonjour on the local network first, then saved addresses (Wi‑Fi, Tailscale).
        await setPhase(.connecting("Recherche de \(mac.name)…"))
        var candidates: [(NWEndpoint, String?)] = []
        log.info("step: bonjour")
        if let local = await browseBonjour(fingerprint: mac.fingerprint, timeout: 1.5) {
            candidates.append((local, nil))
        }
        for host in mac.hosts {
            candidates.append((.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: mac.port)!), host))
        }

        var lastError: Error = HermesError.timeout
        for (endpoint, host) in candidates {
            guard connectionID == myID else { throw CancellationError() }
            log.info("step: connecting \(String(describing: endpoint))")
            await setPhase(.connecting("Connexion à \(host ?? mac.name)…"))
            let framed = FramedConnection(NWConnection(to: endpoint, using: FramedConnection.tcpParameters()), queue: queue)
            do {
                try await framed.start(timeout: 3)
            } catch {
                framed.cancel()
                lastError = error
                continue
            }
            // 3. Mutual authentication. A wrong Mac key aborts immediately — never try another address with it.
            do {
                let channel = try await withTimeout(10) {
                    try await Handshake.runClient(on: framed, pinnedServerKey: mac.publicKey,
                                                  identityPublicKey: identity.publicKeyData,
                                                  name: MacStore.deviceName, pairingToken: pairingToken,
                                                  sign: { try identity.sign($0) })
                }
                guard connectionID == myID else { channel.close(); throw CancellationError() }
                // The Mac confirms with an encrypted "welcome", or closes if this iPhone isn't allowed.
                let first = try await withTimeout(10) { try Message.decode(try await channel.receive()) }
                switch first {
                case .welcome: break
                case .bye(let reason): channel.close(); throw fail("Refusé par le Mac : \(reason)")
                default: channel.close(); throw fail("Réponse inattendue du Mac")
                }
                self.channel = channel
                self.connectedMac = mac
                self.connectedHost = host
                startReceiving(channel, id: myID)
                startPing()
                await MainActor.run {
                    self.macName = mac.name
                    self.phase = .connected
                }
                return
            } catch let e as HermesError {
                framed.cancel()
                if case .authentication = e { throw fail(e.localizedDescription) }
                if case .closed = e {
                    throw fail(pairingToken == nil
                               ? "Le Mac a refusé la connexion. Cet iPhone est‑il toujours autorisé ?"
                               : "Appairage refusé (code expiré ou déjà utilisé).")
                }
                lastError = e
            } catch {
                framed.cancel()
                // Final decisions (refusal, cancellation) must not fall through to the next address.
                if error is CancellationError || (error as NSError).domain == "Hermes" { throw error }
                lastError = error
            }
        }
        throw fail("Mac injoignable : \(lastError.localizedDescription)")
    }

    private func fail(_ message: String) -> Error {
        DispatchQueue.main.async { self.phase = .failed(message) }
        return NSError(domain: "Hermes", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func setPhase(_ p: Phase) async {
        await MainActor.run { self.phase = p }
    }

    private func browseBonjour(fingerprint: String, timeout: TimeInterval) async -> NWEndpoint? {
        await withCheckedContinuation { cont in
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: HermesConstants.bonjourType, domain: nil), using: .tcp)
            var done = false
            let finish: (NWEndpoint?) -> Void = { ep in
                guard !done else { return }
                done = true
                browser.cancel()
                cont.resume(returning: ep)
            }
            browser.browseResultsChangedHandler = { results, _ in
                for r in results {
                    if case let .bonjour(txt) = r.metadata, txt["fp"] == fingerprint {
                        finish(r.endpoint)
                        return
                    }
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { finish(nil) }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    private func withTimeout<T>(_ seconds: TimeInterval, _ op: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw HermesError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    // MARK: Session

    private func startReceiving(_ channel: SecureChannel, id: UUID) {
        receiveTask = Task.detached(priority: .userInitiated) { [weak self] in
            while true {
                do {
                    let msg = try Message.decode(try await channel.receive())
                    self?.handle(msg)
                } catch {
                    guard let self, self.connectionID == id else { return }
                    let reason = (error as? HermesError)?.errorDescription ?? error.localizedDescription
                    self.teardown()
                    await MainActor.run { self.phase = .failed("Session terminée : \(reason)") }
                    return
                }
            }
        }
    }

    private func handle(_ msg: Message) {
        switch msg {
        case let .welcome(name, w, h):
            DispatchQueue.main.async {
                self.macName = name
                if w > 0, h > 0 { self.videoSize = CGSize(width: w, height: h) }
            }
        case let .videoFormat(sps, pps, w, h):
            videoView?.setFormat(sps: sps, pps: pps)
            DispatchQueue.main.async { self.videoSize = CGSize(width: w, height: h) }
        case let .videoFrame(key, _, avcc):
            videoView?.enqueue(avcc: avcc, isKeyframe: key)
            queue.async { self.frameCount += 1 }
        case let .bye(reason):
            teardown()
            DispatchQueue.main.async { self.phase = .failed("Session terminée par le Mac : \(reason)") }
        case let .pong(t):
            let now = UInt64(DispatchTime.now().uptimeNanoseconds / 1000)
            let rtt = Int((now &- t) / 1000)
            DispatchQueue.main.async { self.latencyMs = rtt }
        default:
            break
        }
    }

    private func startPing() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let fps = self.frameCount
            self.frameCount = 0
            DispatchQueue.main.async { self.fps = fps }
            self.send(.ping(UInt64(DispatchTime.now().uptimeNanoseconds / 1000)))
        }
        timer.resume()
        pingTimer = timer
    }

    func send(_ message: Message) {
        channel?.send(message.encoded())
    }

    func requestKeyframe() {
        videoView?.reset()
        send(.requestKeyframe)
    }

    private func teardown() {
        pingTimer?.cancel()
        pingTimer = nil
        channel?.close()
        channel = nil
    }

    func disconnect() {
        if channel != nil { send(.bye(reason: "déconnexion")) }
        connectionID = UUID()
        receiveTask?.cancel()
        receiveTask = nil
        teardown()
        DispatchQueue.main.async {
            self.phase = .idle
            self.latencyMs = nil
            self.fps = 0
        }
    }

    func clearError() {
        if case .failed = phase { phase = .idle }
    }
}

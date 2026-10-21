import Foundation
import CryptoKit

/// Authenticated key exchange + encrypted transport.
///
/// Handshake (SIGMA‑style, every step bound to a running transcript hash):
///   1. iPhone → Mac  ClientHello  { ephemeral X25519 key, mode }
///   2. Mac → iPhone  ServerHello  { ephemeral key, Mac identity key, signature(th1) }
///      The iPhone checks the Mac identity against the key pinned at pairing time.
///   3. iPhone → Mac  ClientAuth   { iPhone identity key, name, signature(th2), [pairing proof] }
///      The Mac accepts only identity keys it already trusts, or a valid one‑time pairing proof.
/// Session keys = HKDF(X25519(eph, eph), salt: th2). Every later frame is ChaCha20‑Poly1305
/// with a strictly increasing counter nonce, so replayed, reordered or altered frames are rejected.
enum Handshake {
    static let version = 1
    static let label = Data("swiftview/handshake/v1".utf8)

    enum Mode: String, Codable { case connect, pair }

    struct ClientHello: Codable {
        var v: Int
        var eph: Data
        var mode: Mode
    }

    struct ServerHello: Codable {
        var v: Int
        var eph: Data
        var serverKey: Data
        var sig: Data
    }

    struct ClientAuth: Codable {
        var clientKey: Data
        var name: String
        var sig: Data
        var pairProof: Data?
    }

    static func transcript1(clientHello: Data, serverEph: Data, serverKey: Data) -> Data {
        var h = SHA256()
        h.update(data: label)
        h.update(data: clientHello)
        h.update(data: serverEph)
        h.update(data: serverKey)
        return Data(h.finalize())
    }

    static func transcript2(th1: Data, serverSig: Data, clientKey: Data, name: String) -> Data {
        var h = SHA256()
        h.update(data: th1)
        h.update(data: serverSig)
        h.update(data: clientKey)
        h.update(data: Data(name.utf8))
        return Data(h.finalize())
    }

    static func pairProof(token: Data, th2: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: th2, using: SymmetricKey(data: token)))
    }

    static func deriveKeys(secret: SharedSecret, th2: Data) -> (c2s: SymmetricKey, s2c: SymmetricKey) {
        let c2s = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: th2, sharedInfo: Data("c2s".utf8), outputByteCount: 32)
        let s2c = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: th2, sharedInfo: Data("s2c".utf8), outputByteCount: 32)
        return (c2s, s2c)
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
    static func encode<T: Encodable>(_ v: T) throws -> Data { try encoder.encode(v) }
    static func decode<T: Decodable>(_ t: T.Type, _ d: Data) throws -> T {
        do { return try decoder.decode(t, from: d) } catch { throw HermesError.badMessage }
    }

    // MARK: Client side (iPhone)

    /// Runs the handshake as the client. `sign` may trigger Face ID.
    static func runClient(
        on framed: FramedConnection,
        pinnedServerKey: Data,
        identityPublicKey: Data,
        name: String,
        pairingToken: Data?,
        sign: (Data) throws -> Data
    ) async throws -> SecureChannel {
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let hello = ClientHello(v: version, eph: eph.publicKey.rawRepresentation, mode: pairingToken == nil ? .connect : .pair)
        let helloData = try encode(hello)
        framed.send(helloData)

        let server = try decode(ServerHello.self, try await framed.receive())
        guard server.v == version else { throw HermesError.authentication("version incompatible") }
        guard server.serverKey == pinnedServerKey else {
            throw HermesError.authentication("l'identité du Mac ne correspond pas (possible usurpation)")
        }
        let th1 = transcript1(clientHello: helloData, serverEph: server.eph, serverKey: server.serverKey)
        guard DeviceIdentity.verify(signature: server.sig, of: th1, publicKey: server.serverKey) else {
            throw HermesError.authentication("signature du Mac invalide")
        }

        let th2 = transcript2(th1: th1, serverSig: server.sig, clientKey: identityPublicKey, name: name)
        let sig = try sign(th2)
        let auth = ClientAuth(clientKey: identityPublicKey, name: name, sig: sig,
                              pairProof: pairingToken.map { pairProof(token: $0, th2: th2) })
        framed.send(try encode(auth))

        let peerEph = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: server.eph)
        let secret = try eph.sharedSecretFromKeyAgreement(with: peerEph)
        let keys = deriveKeys(secret: secret, th2: th2)
        return SecureChannel(framed: framed, sendKey: keys.c2s, receiveKey: keys.s2c)
    }

    // MARK: Server side (Mac)

    struct ServerResult {
        let channel: SecureChannel
        let clientKey: Data
        let clientName: String
        let mode: Mode
    }

    /// Runs the handshake as the server.
    /// `authorize` receives (clientKey, mode, th2, pairProof) and returns whether the client may proceed.
    static func runServer(
        on framed: FramedConnection,
        identity: DeviceIdentity,
        authorize: (_ clientKey: Data, _ name: String, _ mode: Mode, _ th2: Data, _ proof: Data?) -> Bool
    ) async throws -> ServerResult {
        let helloData = try await framed.receive()
        let hello = try decode(ClientHello.self, helloData)
        guard hello.v == version else { throw HermesError.authentication("version incompatible") }
        let peerEph = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hello.eph)

        let eph = Curve25519.KeyAgreement.PrivateKey()
        let serverKey = identity.publicKeyData
        let th1 = transcript1(clientHello: helloData, serverEph: eph.publicKey.rawRepresentation, serverKey: serverKey)
        let sig = try identity.sign(th1)
        framed.send(try encode(ServerHello(v: version, eph: eph.publicKey.rawRepresentation, serverKey: serverKey, sig: sig)))

        let auth = try decode(ClientAuth.self, try await framed.receive())
        let name = String(auth.name.prefix(64))
        let th2 = transcript2(th1: th1, serverSig: sig, clientKey: auth.clientKey, name: auth.name)
        guard DeviceIdentity.verify(signature: auth.sig, of: th2, publicKey: auth.clientKey) else {
            throw HermesError.authentication("signature de l'appareil invalide")
        }
        guard authorize(auth.clientKey, name, hello.mode, th2, auth.pairProof) else {
            throw HermesError.authentication("appareil non autorisé")
        }

        let secret = try eph.sharedSecretFromKeyAgreement(with: peerEph)
        let keys = deriveKeys(secret: secret, th2: th2)
        let channel = SecureChannel(framed: framed, sendKey: keys.s2c, receiveKey: keys.c2s)
        return ServerResult(channel: channel, clientKey: auth.clientKey, clientName: name, mode: hello.mode)
    }
}

/// Encrypted, authenticated message stream on top of a FramedConnection.
final class SecureChannel {
    let framed: FramedConnection
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private let sendLock = NSLock()

    init(framed: FramedConnection, sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.framed = framed
        self.sendKey = sendKey
        self.receiveKey = receiveKey
    }

    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        var c = counter.bigEndian
        withUnsafeBytes(of: &c) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    /// Thread‑safe. Frames are encrypted and handed to the socket in counter order.
    func send(_ plaintext: Data, completion: ((Error?) -> Void)? = nil) {
        sendLock.lock()
        defer { sendLock.unlock() }
        do {
            let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: Self.nonce(sendCounter))
            sendCounter += 1
            framed.send(box.ciphertext + box.tag) { completion?($0) }
        } catch {
            completion?(error)
        }
    }

    /// Must be called from a single reader.
    func receive() async throws -> Data {
        let frame = try await framed.receive()
        guard frame.count >= 16 else { throw HermesError.badMessage }
        let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(receiveCounter),
                                           ciphertext: frame.prefix(frame.count - 16),
                                           tag: frame.suffix(16))
        receiveCounter += 1
        do {
            return try ChaChaPoly.open(box, using: receiveKey)
        } catch {
            throw HermesError.authentication("message altéré")
        }
    }

    func close() {
        framed.cancel()
    }
}

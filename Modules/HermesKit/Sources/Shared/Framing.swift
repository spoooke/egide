import Foundation
import Network
import Synchronization

enum HermesError: LocalizedError {
    case closed
    case timeout
    case frameTooLarge
    case badMessage
    case authentication(String)

    var errorDescription: String? {
        switch self {
        case .closed: return "Connexion fermée"
        case .timeout: return "Délai dépassé"
        case .frameTooLarge: return "Message trop volumineux"
        case .badMessage: return "Message invalide"
        case .authentication(let why): return "Authentification refusée : \(why)"
        }
    }
}

/// TCP connection carrying length‑prefixed frames (4 bytes big‑endian + payload).
final class FramedConnection: Sendable {
    static let maxFrameSize = 16 * 1024 * 1024

    let connection: NWConnection
    let queue: DispatchQueue

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = false
        return params
    }

    /// Starts the connection and waits until it is ready.
    func start(timeout: TimeInterval = 5) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // L'état de la connexion et le délai arrivent chacun de leur côté : on ne reprend qu'une fois.
            let resumed = Mutex(false)
            let finish: @Sendable (Result<Void, Error>) -> Void = { result in
                guard !resumed.withLock({ deja in defer { deja = true }; return deja }) else { return }
                cont.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.success(()))
                case .failed(let err): finish(.failure(err))
                case .waiting(let err): finish(.failure(err))
                case .cancelled: finish(.failure(HermesError.closed))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if !resumed.withLock({ $0 }) { self.connection.cancel() }
                finish(.failure(HermesError.timeout))
            }
        }
    }

    func send(_ payload: Data, completion: ((NWError?) -> Void)? = nil) {
        var frame = Data(capacity: payload.count + 4)
        var len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { err in completion?(err) })
    }

    func receive() async throws -> Data {
        let header = try await receiveExactly(4)
        let len = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard len <= Self.maxFrameSize else { throw HermesError.frameTooLarge }
        if len == 0 { return Data() }
        return try await receiveExactly(len)
    }

    private func receiveExactly(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error); return }
                if let data, data.count == count { cont.resume(returning: data); return }
                if isComplete { cont.resume(throwing: HermesError.closed); return }
                cont.resume(throwing: HermesError.badMessage)
            }
        }
    }

    func cancel() {
        connection.cancel()
    }
}

// MARK: - Binary helpers

struct ByteWriter {
    private(set) var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { var b = v.bigEndian; withUnsafeBytes(of: &b) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { var b = v.bigEndian; withUnsafeBytes(of: &b) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { var b = v.bigEndian; withUnsafeBytes(of: &b) { data.append(contentsOf: $0) } }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func bytes(_ d: Data) { data.append(d) }
    mutating func blob16(_ d: Data) { u16(UInt16(d.count)); data.append(d) }
}

struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var remaining: Int { data.endIndex - offset }

    private mutating func take(_ n: Int) throws -> Data {
        guard n >= 0, remaining >= n else { throw HermesError.badMessage }
        defer { offset += n }
        return data.subdata(in: offset..<(offset + n))
    }

    private mutating func integer<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let d = try take(MemoryLayout<T>.size)
        return d.withUnsafeBytes { T(bigEndian: $0.loadUnaligned(as: T.self)) }
    }

    mutating func u8() throws -> UInt8 { try integer(UInt8.self) }
    mutating func u16() throws -> UInt16 { try integer(UInt16.self) }
    mutating func u32() throws -> UInt32 { try integer(UInt32.self) }
    mutating func u64() throws -> UInt64 { try integer(UInt64.self) }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    mutating func blob16() throws -> Data { try take(Int(try u16())) }
    mutating func rest() throws -> Data { try take(remaining) }
}

import Foundation

/// Messages exchanged once the secure channel is established.
enum Message {
    // Mac → iPhone
    case welcome(macName: String, width: Int, height: Int)
    case videoFormat(sps: Data, pps: Data, width: Int, height: Int)
    case videoFrame(isKeyframe: Bool, timestampMicros: UInt64, avcc: Data)
    case bye(reason: String)
    // iPhone → Mac
    case pointer(x: Float, y: Float)
    case button(MouseButton, down: Bool, x: Float, y: Float)
    case scroll(dx: Float, dy: Float)
    case text(String)
    case key(code: UInt16, modifiers: Modifiers)
    case keyChar(String, modifiers: Modifiers)
    case requestKeyframe
    case ping(UInt64)
    case pong(UInt64)

    enum MouseButton: UInt8 { case left = 0, right = 1 }

    struct Modifiers: OptionSet, Hashable {
        let rawValue: UInt32
        static let command = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let control = Modifiers(rawValue: 1 << 2)
        static let shift = Modifiers(rawValue: 1 << 3)
    }

    private enum Tag: UInt8 {
        case welcome = 0x01, videoFormat = 0x02, videoFrame = 0x03
        case pointer = 0x10, button = 0x11, scroll = 0x12, text = 0x13, key = 0x14, keyChar = 0x15
        case requestKeyframe = 0x16, ping = 0x17, pong = 0x18
        case bye = 0x04
    }

    func encoded() -> Data {
        var w = ByteWriter()
        switch self {
        case let .welcome(name, width, height):
            w.u8(Tag.welcome.rawValue); w.u32(UInt32(width)); w.u32(UInt32(height)); w.bytes(Data(name.utf8))
        case let .videoFormat(sps, pps, width, height):
            w.u8(Tag.videoFormat.rawValue); w.u32(UInt32(width)); w.u32(UInt32(height)); w.blob16(sps); w.blob16(pps)
        case let .videoFrame(key, ts, avcc):
            w.u8(Tag.videoFrame.rawValue); w.u8(key ? 1 : 0); w.u64(ts); w.bytes(avcc)
        case let .bye(reason):
            w.u8(Tag.bye.rawValue); w.bytes(Data(reason.utf8))
        case let .pointer(x, y):
            w.u8(Tag.pointer.rawValue); w.f32(x); w.f32(y)
        case let .button(b, down, x, y):
            w.u8(Tag.button.rawValue); w.u8(b.rawValue); w.u8(down ? 1 : 0); w.f32(x); w.f32(y)
        case let .scroll(dx, dy):
            w.u8(Tag.scroll.rawValue); w.f32(dx); w.f32(dy)
        case let .text(s):
            w.u8(Tag.text.rawValue); w.bytes(Data(s.utf8))
        case let .key(code, mods):
            w.u8(Tag.key.rawValue); w.u16(code); w.u32(mods.rawValue)
        case let .keyChar(s, mods):
            w.u8(Tag.keyChar.rawValue); w.u32(mods.rawValue); w.bytes(Data(s.utf8))
        case .requestKeyframe:
            w.u8(Tag.requestKeyframe.rawValue)
        case let .ping(t):
            w.u8(Tag.ping.rawValue); w.u64(t)
        case let .pong(t):
            w.u8(Tag.pong.rawValue); w.u64(t)
        }
        return w.data
    }

    static func decode(_ data: Data) throws -> Message {
        var r = ByteReader(data)
        guard let tag = Tag(rawValue: try r.u8()) else { throw HermesError.badMessage }
        func string(_ d: Data) throws -> String {
            guard let s = String(data: d, encoding: .utf8) else { throw HermesError.badMessage }
            return s
        }
        func unit(_ v: Float) throws -> Float {
            guard v.isFinite else { throw HermesError.badMessage }
            return min(max(v, 0), 1)
        }
        switch tag {
        case .welcome:
            let w = Int(try r.u32()), h = Int(try r.u32())
            return .welcome(macName: try string(try r.rest()), width: w, height: h)
        case .videoFormat:
            let w = Int(try r.u32()), h = Int(try r.u32())
            return .videoFormat(sps: try r.blob16(), pps: try r.blob16(), width: w, height: h)
        case .videoFrame:
            let key = try r.u8() == 1
            let ts = try r.u64()
            return .videoFrame(isKeyframe: key, timestampMicros: ts, avcc: try r.rest())
        case .bye:
            return .bye(reason: String(try string(try r.rest()).prefix(200)))
        case .pointer:
            return .pointer(x: try unit(try r.f32()), y: try unit(try r.f32()))
        case .button:
            guard let b = MouseButton(rawValue: try r.u8()) else { throw HermesError.badMessage }
            let down = try r.u8() == 1
            return .button(b, down: down, x: try unit(try r.f32()), y: try unit(try r.f32()))
        case .scroll:
            let dx = try r.f32(), dy = try r.f32()
            guard dx.isFinite, dy.isFinite else { throw HermesError.badMessage }
            return .scroll(dx: max(-2000, min(2000, dx)), dy: max(-2000, min(2000, dy)))
        case .text:
            return .text(String(try string(try r.rest()).prefix(4096)))
        case .key:
            return .key(code: try r.u16(), modifiers: Modifiers(rawValue: try r.u32()))
        case .keyChar:
            let mods = Modifiers(rawValue: try r.u32())
            return .keyChar(String(try string(try r.rest()).prefix(8)), modifiers: mods)
        case .requestKeyframe:
            return .requestKeyframe
        case .ping:
            return .ping(try r.u64())
        case .pong:
            return .pong(try r.u64())
        }
    }
}

/// Content of the pairing QR code shown by the Mac.
struct PairingPayload: Codable {
    var v: Int = 1
    /// Mac display name
    var n: String
    /// Mac identity public key (x963)
    var k: Data
    /// One‑time pairing secret (32 bytes, valid 5 minutes)
    var t: Data
    /// Addresses the Mac can be reached on
    var h: [String]
    /// TCP port
    var p: UInt16

    static let scheme = "swiftview"

    func url() throws -> String {
        let json = try JSONEncoder().encode(self)
        let b64 = json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(Self.scheme)://pair?p=\(b64)"
    }

    static func parse(_ string: String) -> PairingPayload? {
        guard let comps = URLComponents(string: string), comps.scheme == scheme, comps.host == "pair",
              var b64 = comps.queryItems?.first(where: { $0.name == "p" })?.value else { return nil }
        b64 = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let payload = try? JSONDecoder().decode(PairingPayload.self, from: data),
              payload.v == 1, payload.t.count == 32 else { return nil }
        return payload
    }
}

enum HermesConstants {
    static let port: UInt16 = 47800
    static let bonjourType = "_swiftview._tcp"
}

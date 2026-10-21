import XCTest
@testable import HermesKit

final class HermesKitTests: XCTestCase {
    func testRoutes() {
        XCTAssertEqual(HermesRoute(path: []), .connect)
        XCTAssertEqual(HermesRoute(path: ["pair"]), .pair)
    }

    func testPairingLinkRoundTrip() throws {
        let payload = PairingPayload(n: "Mac mini", k: Data(repeating: 4, count: 65), t: Data(repeating: 7, count: 32),
                                     h: ["192.168.1.10", "mac-mini.tailnet.ts.net"], p: HermesConstants.port)
        let parsed = try XCTUnwrap(PairingPayload.parse(try payload.url()))
        XCTAssertEqual(parsed.n, "Mac mini")
        XCTAssertEqual(parsed.k, payload.k)
        XCTAssertEqual(parsed.t, payload.t)
        XCTAssertEqual(parsed.h, payload.h)
        XCTAssertEqual(parsed.p, 47800)
    }

    func testPairingLinkRejected() throws {
        XCTAssertNil(PairingPayload.parse("https://example.com"))
        // Secret de la mauvaise taille.
        let bad = PairingPayload(n: "Mac", k: Data([1]), t: Data(repeating: 1, count: 8), h: [], p: 1)
        XCTAssertNil(PairingPayload.parse(try bad.url()))
    }

    func testMessagesRoundTrip() throws {
        let messages: [Message] = [
            .pointer(x: 0.25, y: 0.75),
            .button(.right, down: true, x: 0.5, y: 0.5),
            .keyChar("é", modifiers: [.command, .shift]),
            .bye(reason: "Session coupée"),
        ]
        for message in messages {
            XCTAssertEqual(String(describing: try Message.decode(message.encoded())), String(describing: message))
        }
    }

    func testSignatureAndFingerprint() throws {
        let identity = try DeviceIdentity.create(requireBiometry: false)
        let message = Data("bonjour".utf8)
        let signature = try identity.sign(message)
        XCTAssertTrue(DeviceIdentity.verify(signature: signature, of: message, publicKey: identity.publicKeyData))
        XCTAssertFalse(DeviceIdentity.verify(signature: signature, of: Data("autre".utf8), publicKey: identity.publicKeyData))
        XCTAssertEqual(DeviceIdentity.fingerprint(of: identity.publicKeyData).count, 14) // « XXXX-XXXX-XXXX »
    }
}

import XCTest
@testable import ArgosKit

final class ArgosKitTests: XCTestCase {
    func testRoutes() {
        XCTAssertEqual(ArgosRoute(path: []), .dashboard)
        XCTAssertEqual(ArgosRoute(path: ["device", "mac-mini"]), .device("mac-mini"))
        XCTAssertEqual(ArgosRoute(path: ["device"]), .dashboard)
        XCTAssertEqual(ArgosRoute(path: ["network"]), .network)
        XCTAssertEqual(ArgosRoute(path: ["events"]), .events)
        XCTAssertNil(ArgosRoute.dashboard.route)
        XCTAssertEqual(ArgosRoute.device("a").route, .device("a"))
    }

    func testPairingLink() {
        let token = String(repeating: "ab12", count: 8)
        let c = PairingLink.parse("https://mon-mac.tailnet.ts.net/#token=\(token)")
        XCTAssertEqual(c?.baseURL.absoluteString, "https://mon-mac.tailnet.ts.net")
        XCTAssertEqual(c?.token, token)
        XCTAssertEqual(PairingLink.parse("http://127.0.0.1:8787/#token=\(token)")?.baseURL.port, 8787)
    }

    func testPairingLinkRejected() {
        XCTAssertNil(PairingLink.parse("https://mon-mac.tailnet.ts.net/"))
        XCTAssertNil(PairingLink.parse("https://mon-mac.tailnet.ts.net/#token=court"))
        XCTAssertNil(PairingLink.parse("https://mon-mac.tailnet.ts.net/#token=\(String(repeating: "z", count: 32))"))
        XCTAssertNil(PairingLink.parse("ftp://mon-mac/#token=\(String(repeating: "a", count: 32))"))
    }

    private func deviceJSON(accepted: String) -> Data {
        Data("""
        {"kind":"agent","lastSeen":"2026-10-12T08:00:00Z","online":true,
         "latest":{"deviceId":"mac","hostname":"mac","os":"darwin","osVersion":"macOS 27","score":80,"checks":[
           {"id":"firewall","title":"Pare-feu","category":"Réseau","status":"fail","severity":"high"},
           {"id":"filevault","title":"FileVault","category":"Disque","status":"pass","severity":"high"},
           {"id":"updates","title":"Mises à jour","category":"Système","status":"warn","severity":"medium"}]}\(accepted)}
        """.utf8)
    }

    func testAcceptedRisk() throws {
        // Un risque accepté dont la révision est dépassée, et une acceptation restée sur un point revenu à OK.
        let accepted = """
        ,"accepted":{"firewall":{"reason":"Matériel incompatible","at":"2026-01-01T10:00:00Z","reviewAt":"2026-07-01T10:00:00Z"},
                     "filevault":{"reason":"Ancien","at":"2026-10-01T10:00:00Z","reviewAt":"2099-04-01T10:00:00Z"}}
        """
        let d = try APIClient.decoder.decode(DeviceDetail.self, from: deviceJSON(accepted: accepted))
        let checks = d.latest.checks
        XCTAssertEqual(d.acceptance(of: checks[0])?.reason, "Matériel incompatible")
        XCTAssertEqual(d.acceptance(of: checks[0])?.isDue, true)
        XCTAssertNil(d.acceptance(of: checks[1]))
        XCTAssertNil(d.acceptance(of: checks[2]))
        XCTAssertEqual(d.accepted?["filevault"]?.isDue, false)

        // Un serveur plus ancien n'envoie pas le champ.
        XCTAssertNil(try APIClient.decoder.decode(DeviceDetail.self, from: deviceJSON(accepted: "")).accepted)
    }

    func testAcceptedCount() throws {
        let json = """
        {"id":"mac","kind":"agent","hostname":"mac","os":"darwin","osVersion":"macOS 27","score":80,
         "lastSeen":"2026-10-12T08:00:00Z","online":true,"counts":{"fail":1,"accepted":2}}
        """
        let s = try APIClient.decoder.decode(DeviceSummary.self, from: Data(json.utf8))
        XCTAssertEqual(s.accepted, 2)
        XCTAssertEqual(s.fails, 1)
    }

    func testAppLockRelocksAfterAMinuteAway() {
        // Verrouillé au départ ; un aller-retour rapide ne reverrouille pas après déverrouillage.
        MainActor.assumeIsolated {
            let lock = AppLock()
            XCTAssertTrue(lock.locked)
            lock.locked = false
            lock.didEnterBackground()
            lock.willEnterForeground()
            XCTAssertFalse(lock.locked)
        }
    }

    func testDeviceProfile() throws {
        let json = Data("""
        [{"id":"n1","name":"Maison","subnet":"192.168.1.0/24","gatewayIp":"192.168.1.1","scannedBy":"mac",
          "lastScan":"2026-10-12T08:00:00Z","unapproved":1,"devices":[
           {"mac":"aa:bb","ip":"192.168.1.20","approved":false,"lastSeen":"2026-10-12T08:00:00Z","online":true,
            "probeRequested":true,"probeRequestedAt":"2026-10-12T08:01:00.123Z",
            "profile":{"at":"2026-10-12T08:00:30Z","by":"mac","kind":"Enceinte connectée",
              "facts":[{"label":"Service","value":"_airplay._tcp"}],
              "ports":[{"port":23,"name":"Telnet","risky":true},{"port":80}]}},
           {"mac":"cc:dd","ip":"192.168.1.21","approved":true,"lastSeen":"2026-10-12T08:00:00Z","online":false,
            "profile":{"at":"2026-10-12T08:00:30Z","by":"mac"}},
           {"mac":"ee:ff","ip":"192.168.1.22","approved":true,"lastSeen":"2026-10-12T08:00:00Z","online":true}]}]
        """.utf8)
        let devices = try XCTUnwrap(APIClient.decoder.decode([LocalNetwork].self, from: json).first?.devices)
        XCTAssertEqual(devices[0].probeRequested, true)
        XCTAssertNotNil(devices[0].probeRequestedAt)
        XCTAssertEqual(devices[0].profile?.kind, "Enceinte connectée")
        XCTAssertEqual(devices[0].profile?.facts?.first?.value, "_airplay._tcp")
        XCTAssertEqual(devices[0].profile?.ports?.map(\.risky), [true, nil])
        XCTAssertEqual(devices[0].profile?.isEmpty, false)
        XCTAssertEqual(devices[1].profile?.isEmpty, true)
        XCTAssertNil(devices[2].profile)
        XCTAssertNil(devices[2].probeRequested)
    }
}

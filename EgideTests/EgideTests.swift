import Foundation
import Testing
@testable import Egide

struct DeepLinkTests {
    @Test func egideModule() throws {
        let link = try #require(DeepLink(url: URL(string: "egide://argos/device/mac-mini")!))
        #expect(link.target == .module(.argos))
        #expect(link.path == ["device", "mac-mini"])
    }

    @Test func egideModuleWithoutPath() throws {
        let link = try #require(DeepLink(url: URL(string: "egide://money")!))
        #expect(link.target == .module(.money))
        #expect(link.path.isEmpty)
    }

    @Test func settings() throws {
        #expect(DeepLink(url: URL(string: "egide://settings")!)?.target == .settings)
    }

    @Test func legacyMuseScheme() throws {
        let link = try #require(DeepLink(url: URL(string: "muse://capture")!))
        #expect(link.target == .module(.muse))
        #expect(link.path == ["capture"])
    }

    /// Lien partagé vers Cerbère : il arrive entier (paramètres compris) en dernier élément du chemin.
    @Test func lienPartageVersCerbere() throws {
        let link = try #require(DeepLink(url: URL(string: "egide://cerbere/audit?lien=https%3A%2F%2Fgithub.com%2Fa%2Fb%3Ftab%3Dreadme")!))
        #expect(link.target == .module(.cerbere))
        #expect(link.path == ["audit", "https://github.com/a/b?tab=readme"])
        #expect(DeepLink(url: URL(string: "egide://cerbere")!)?.path == [])
    }

    @Test func rejected() {
        #expect(DeepLink(url: URL(string: "egide://inconnu/x")!) == nil)
        #expect(DeepLink(url: URL(string: "https://argos.example")!) == nil)
    }
}

struct TabLayoutTests {
    @Test func roundTrip() {
        var layout = TabLayout.standard
        layout.move(fromOffsets: [3], toOffset: 0)
        layout.setHidden(.hermes, true)
        #expect(Array(layout.order.prefix(4)) == [.money, .argos, .hermes, .muse])
        #expect(layout.visible == layout.order.filter { $0 != .hermes })
        #expect(TabLayout(storage: layout.storage) == layout)
    }

    @Test func toleratesUnknownAndMissingModules() {
        let layout = TabLayout(storage: "muse,ancien,muse|ancien,money")
        #expect(layout.order == [.muse] + Module.allCases.filter { $0 != .muse })
        #expect(layout.hidden == [.money])
    }

    @Test func emptyStorage() {
        #expect(TabLayout(storage: "") == .standard)
    }
}

@MainActor
struct AppRouterTests {
    @Test func sameLinkTwiceIsTwoRequests() {
        let router = AppRouter()
        router.open(.module(.muse), path: ["capture"])
        let first = router.links[.muse]
        router.open(.module(.muse), path: ["capture"])
        #expect(router.links[.muse]?.path == ["capture"])
        #expect(router.links[.muse] != first)
        #expect(router.tabRequest?.target == .module(.muse))
    }

    @Test func settings() {
        let router = AppRouter()
        router.open(.settings)
        #expect(router.tabRequest?.target == .settings)
        #expect(router.links.isEmpty)
    }
}

struct GlobalBackupTests {
    @Test func roundTrip() throws {
        let backup = GlobalBackup(createdAt: Date(timeIntervalSince1970: 1_790_000_000), tabLayout: "muse,money,argos,hermes|hermes",
                                  modules: ["muse": Data("{\"ideas\":[]}".utf8)])
        #expect(try GlobalBackup.decode(try backup.encoded()) == backup)
    }

    @Test func unknownVersionRejected() throws {
        var backup = GlobalBackup(createdAt: .now, tabLayout: "", modules: [:])
        backup.version = 2
        #expect(throws: (any Error).self) { try GlobalBackup.decode(try backup.encoded()) }
    }

    @Test func notABackup() {
        #expect(throws: (any Error).self) { try GlobalBackup.decode(Data("{\"ideas\":[]}".utf8)) }
    }
}

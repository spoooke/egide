import ArgosKit
import CerbereKit
import HephaistosKit
import MnemosyneKit
import SwiftUI
import UserNotifications

@main
struct EgideApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    private let notificationPresenter = NotificationPresenter()

    init() {
        UNUserNotificationCenter.current().delegate = notificationPresenter
        // Héphaïstos lit la température du Mac par la connexion de l'app Argos.
        HephaistosKit.charger = { try await ArgosKit.fetch("api/temperature") }
        // Cerbère demande ses audits au Mac, et relit les rapports, par la même connexion.
        CerbereKit.serveur = { try await ArgosKit.call($0, method: $1, json: $2) }
        // Mnemosyne: the Mac's last Time Machine backup, and « Sauvegarder maintenant ».
        MnemosyneKit.server = { try await ArgosKit.call($0, method: $1, json: $2) }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Orientation autorisée selon l'onglet affiché (Info.plist déclare portrait + paysage).
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientations: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientations
    }

    /// Applique l'orientation de l'onglet choisi ; revient en portrait en quittant Hermès.
    static func setOrientations(_ mask: UIInterfaceOrientationMask) {
        guard mask != orientations else { return }
        orientations = mask
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            if mask == .portrait {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
    }
}

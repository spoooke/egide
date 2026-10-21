import HephaistosKit
import Observation
import UserNotifications

/// Envoi des alertes en notifications du Mac.
@MainActor
@Observable
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    /// Vrai quand les notifications d'Héphaïstos sont coupées dans Réglages Système.
    private(set) var refusees = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Demande l'autorisation au premier appel (le système ne pose la question qu'une fois), puis relit l'état.
    func verifier() async {
        let centre = UNUserNotificationCenter.current()
        _ = try? await centre.requestAuthorization(options: [.alert, .sound])
        let refus = await centre.notificationSettings().authorizationStatus == .denied
        if refus != refusees { refusees = refus }
    }

    func envoyer(_ avis: Avis) {
        let contenu = UNMutableNotificationContent()
        contenu.title = avis.titre
        contenu.body = avis.message
        contenu.sound = .default
        Task {
            await verifier()
            // Même identifiant par sorte d'alerte : une nouvelle alerte remplace la précédente au lieu de s'empiler.
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "hephaistos.alerte.\(avis.sorte.rawValue)", content: contenu, trigger: nil))
        }
    }

    /// Affiche aussi la bannière quand la fenêtre d'Héphaïstos est ouverte.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

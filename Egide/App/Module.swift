import EgideUI
import SwiftUI
import ArgosKit
import HermesKit
import MuseKit
import PactoleKit
import HephaistosKit
import CerbereKit
import IrisKit
import MnemosyneKit

/// Les outils d'Égide, un onglet chacun. Ajouter un module : scripts/new-module.sh (voir README).
enum Module: String, CaseIterable, Identifiable, Codable {
    case argos, hermes, muse, money, hephaistos, cerbere, iris, mnemosyne

    var id: String { rawValue }

    var title: String {
        switch self {
        case .argos: ArgosKit.title
        case .hermes: HermesKit.title
        case .muse: MuseKit.title
        case .money: PactoleKit.title
        case .hephaistos: HephaistosKit.title
        case .cerbere: CerbereKit.title
        case .iris: IrisKit.title
        case .mnemosyne: MnemosyneKit.title
        }
    }

    var systemImage: String {
        switch self {
        case .argos: ArgosKit.systemImage
        case .hermes: HermesKit.systemImage
        case .muse: MuseKit.systemImage
        case .money: PactoleKit.systemImage
        case .hephaistos: HephaistosKit.systemImage
        case .cerbere: CerbereKit.systemImage
        case .iris: IrisKit.systemImage
        case .mnemosyne: MnemosyneKit.systemImage
        }
    }

    /// Icône de l'app de l'outil (Assets : Icone-<module>, scripts/make-module-icons.swift), sur l'écran d'accueil.
    /// Night City has its own set (scripts/make-night-city-icons.swift).
    var iconName: String { EgideTheme.palette == .nightCity ? "Icone-\(rawValue)-nuit" : "Icone-\(rawValue)" }

    /// Une ligne sous la tuile de l'Accueil (nil : rien à afficher).
    @MainActor
    func summary() async -> String? {
        switch self {
        case .argos: await ArgosKit.summary()
        case .hermes: await HermesKit.summary()
        case .muse: await MuseKit.summary()
        case .money: await PactoleKit.summary()
        case .hephaistos: await HephaistosKit.summary()
        case .cerbere: await CerbereKit.summary()
        case .iris: await IrisKit.summary()
        case .mnemosyne: await MnemosyneKit.summary()
        }
    }

    /// Données du module pour la sauvegarde globale (nil : rien à sauvegarder).
    @MainActor
    func backup() throws -> Data? {
        switch self {
        case .argos: try ArgosKit.backup()
        case .hermes: try HermesKit.backup()
        case .muse: try MuseKit.backup()
        case .money: try PactoleKit.backup()
        case .hephaistos: try HephaistosKit.backup()
        case .cerbere: try CerbereKit.backup()
        case .iris: try IrisKit.backup()
        case .mnemosyne: try MnemosyneKit.backup()
        }
    }

    /// Restaure les données d'une sauvegarde globale ; renvoie un compte rendu court.
    @MainActor
    func restore(_ data: Data) throws -> String {
        switch self {
        case .argos: try ArgosKit.restore(data)
        case .hermes: try HermesKit.restore(data)
        case .muse: try MuseKit.restore(data)
        case .money: try PactoleKit.restore(data)
        case .hephaistos: try HephaistosKit.restore(data)
        case .cerbere: try CerbereKit.restore(data)
        case .iris: try IrisKit.restore(data)
        case .mnemosyne: try MnemosyneKit.restore(data)
        }
    }

    /// Hermès seul passe en paysage (vidéo de l'écran du Mac) ; le reste de l'app reste en portrait.
    var orientations: UIInterfaceOrientationMask {
        self == .hermes ? .allButUpsideDown : .portrait
    }

    @MainActor @ViewBuilder
    /// `onHome` : bouton « Précédent » de l'écran racine du module, vers l'Accueil.
    /// `isActive` : onglet affiché (Hermès coupe sa session sinon).
    func rootView(link: ModuleLink?, isActive: Bool, onHome: @escaping @MainActor @Sendable () -> Void) -> some View {
        let path = link?.path ?? []
        switch self {
        case .argos: ArgosRootView(path: path, onHome: onHome)
        case .hermes: HermesRootView(path: path, isActive: isActive, onHome: onHome)
        case .muse: MuseRootView(path: path, request: link?.request ?? 0, onHome: onHome)
        case .money: PactoleRootView(path: path, request: link?.request ?? 0, onHome: onHome)
        case .hephaistos: HephaistosRootView(path: path, request: link?.request ?? 0, onHome: onHome)
        case .cerbere: CerbereRootView(path: path, request: link?.request ?? 0, onHome: onHome)
        case .iris: IrisRootView(path: path, request: link?.request ?? 0, onHome: onHome)
        case .mnemosyne: MnemosyneRootView(path: path, request: link?.request ?? 0, onHome: onHome)
        }
    }
}

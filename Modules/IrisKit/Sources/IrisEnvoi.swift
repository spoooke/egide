import CoreGraphics
import Foundation
import MessageUI

/// Contenu du mail d'un scan : destinataires des réglages, objet, PDF joint.
public enum IrisMail {
    /// « Scan · Ticket 2026-10-16 ».
    public static func objet(_ reglages: IrisReglages, scan: IrisScan) -> String {
        "\(reglages.objetEffectif) · \(scan.nom)"
    }

    /// Ce qu'ouvre « Envoyer » : la fenêtre Mail, la feuille de partage si l'iPhone n'a pas de compte Mail,
    /// ou les réglages tant que les adresses ne sont pas saisies.
    public enum Voie: Equatable, Sendable {
        case mail, secours, reglages
    }

    public static func voie(_ reglages: IrisReglages, peutEnvoyer: Bool) -> Voie {
        guard reglages.complet else { return .reglages }
        return peutEnvoyer ? .mail : .secours
    }
}

/// Issue d'un envoi.
public enum IrisResultat: String, Codable, Sendable {
    case envoye, annule, brouillon, echec, partage

    public var titre: String {
        switch self {
        case .envoye: "Envoyé"
        case .annule: "Annulé"
        case .brouillon: "Brouillon"
        case .echec: "Échec"
        case .partage: "Partagé"
        }
    }

    public var systemImage: String {
        switch self {
        case .envoye: "paperplane"
        case .annule: "xmark"
        case .brouillon: "tray"
        case .echec: "exclamationmark.triangle"
        case .partage: "square.and.arrow.up"
        }
    }

    public init(_ resultat: MFMailComposeResult) {
        switch resultat {
        case .sent: self = .envoye
        case .saved: self = .brouillon
        case .failed: self = .echec
        default: self = .annule
        }
    }
}

/// Une ligne de l'historique. Jamais d'adresse : seulement le scan et l'issue.
public struct IrisEnvoi: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var nom: String
    public var date: Date
    public var pages: Int
    public var resultat: IrisResultat

    public init(nom: String, date: Date = .now, pages: Int, resultat: IrisResultat) {
        self.nom = nom
        self.date = date
        self.pages = pages
        self.resultat = resultat
    }
}

/// Historique des envois, du plus récent au plus ancien, rangé sur l'iPhone (UserDefaults).
public struct IrisHistorique {
    static let cle = "iris.historique"
    public static let limite = 100

    private let stockage: UserDefaults

    public init(_ stockage: UserDefaults = .standard) {
        self.stockage = stockage
    }

    public func liste() -> [IrisEnvoi] {
        guard let data = stockage.data(forKey: Self.cle),
              let envois = try? JSONDecoder().decode([IrisEnvoi].self, from: data) else { return [] }
        return envois
    }

    /// Ajoute l'envoi en tête ; les plus anciens au-delà de la limite sont oubliés.
    public func ajouter(_ envoi: IrisEnvoi) {
        let envois = Array(([envoi] + liste()).prefix(Self.limite))
        if let data = try? JSONEncoder().encode(envois) { stockage.set(data, forKey: Self.cle) }
    }
}

extension IrisScan {
    /// Nombre de pages du PDF (0 s'il est illisible).
    public var pages: Int {
        CGPDFDocument(url as CFURL)?.numberOfPages ?? 0
    }
}

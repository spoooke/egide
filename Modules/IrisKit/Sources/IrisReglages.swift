import Foundation

/// Réglages d'Iris, rangés sur l'iPhone seulement (UserDefaults). Les destinataires sont saisis dans l'app,
/// jamais écrits dans le code ni dans le dépôt.
public struct IrisReglages: Codable, Equatable, Sendable {
    /// Deux adresses au plus ; une case vide est ignorée.
    public var destinataires: [String]
    /// Début de l'objet du mail, suivi du nom du scan (« Scan · Ticket 2026-10-16 »).
    public var objet: String
    /// Garder une copie du scan dans Photos.
    public var garderDansPhotos: Bool

    public static let nombreDestinataires = 2
    public static let objetParDefaut = "Scan"

    public init(destinataires: [String] = [], objet: String = IrisReglages.objetParDefaut, garderDansPhotos: Bool = false) {
        self.destinataires = destinataires
        self.objet = objet
        self.garderDansPhotos = garderDansPhotos
    }

    /// Adresses prêtes pour l'envoi : espaces retirés, cases vides et doublons écartés.
    public var adresses: [String] {
        var vues = Set<String>()
        return destinataires
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && vues.insert($0.lowercased()).inserted }
    }

    /// Prêt à envoyer : au moins une adresse, et toutes valides.
    public var complet: Bool {
        !adresses.isEmpty && adresses.allSatisfy(Self.adresseValide)
    }

    /// Objet utilisé : celui des réglages, ou « Scan » s'il est vide.
    public var objetEffectif: String {
        let texte = objet.trimmingCharacters(in: .whitespacesAndNewlines)
        return texte.isEmpty ? Self.objetParDefaut : texte
    }

    /// Contrôle simple d'une adresse : une partie avant @, un domaine avec un point, ni espace ni chevron.
    public static func adresseValide(_ adresse: String) -> Bool {
        let parties = adresse.split(separator: "@", omittingEmptySubsequences: false)
        guard parties.count == 2, !parties[0].isEmpty, adresse.count <= 254 else { return false }
        let domaine = parties[1]
        guard let point = domaine.lastIndex(of: "."), point != domaine.startIndex,
              domaine.distance(from: point, to: domaine.endIndex) > 2 else { return false }
        return !adresse.contains(where: { $0.isWhitespace || "<>,;:\"()[]\\".contains($0) })
    }
}

extension IrisReglages {
    static let cle = "iris.reglages"

    /// Réglages enregistrés (valeurs par défaut au premier lancement).
    public static func charger(_ stockage: UserDefaults = .standard) -> IrisReglages {
        guard let data = stockage.data(forKey: cle),
              let reglages = try? JSONDecoder().decode(IrisReglages.self, from: data) else { return IrisReglages() }
        return reglages
    }

    public func enregistrer(_ stockage: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { stockage.set(data, forKey: Self.cle) }
    }
}

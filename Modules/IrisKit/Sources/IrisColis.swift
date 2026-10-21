import Foundation
import ImageIO
import Security
import UniformTypeIdentifiers

// Fichier compilé aussi dans l'extension de partage (cible EgidePartage, voir project.yml).

/// Un fichier partagé vers Iris depuis Photos ou Fichiers : son type (UTType), son nom, son contenu.
public struct IrisFichierPartage: Codable, Equatable, Sendable {
    public var type: String
    public var nom: String
    public var data: Data

    public init(type: String, nom: String, data: Data) {
        self.type = type
        self.nom = nom
        self.data = data
    }
}

/// Passage des fichiers de l'extension de partage à Iris, par un groupe du trousseau commun aux deux
/// (`IrisGroupeTrousseau` dans les Info.plist ; pas de groupe d'apps avec un compte gratuit, et un presse-papiers
/// nommé ne passe pas d'un processus à l'autre). Iris le lit puis le vide à l'ouverture de egide://iris/partage.
/// Rien ne quitte l'iPhone : élément propre à cet appareil, jamais synchronisé.
public enum IrisColis {
    public static let lien = URL(string: "egide://iris/partage")!
    /// 20 fichiers et 40 Mo au plus par partage ; au-delà, le fichier passe sans contenu et Iris l'écarte.
    public static let nombreMax = 20
    public static let tailleMax = 40_000_000
    /// Photos réduites dans l'extension à la taille que garde Iris (IrisImage.coteMax), sans métadonnées.
    public static let coteImage = 2000
    static let tailleMorceau = 1_000_000

    static let service = "com.spoooke.egide.iris.partage"

    /// Dépose les fichiers (extension). false si le trousseau refuse.
    @discardableResult
    public static func deposer(_ fichiers: [IrisFichierPartage]) -> Bool {
        guard let groupe = groupe, let paquet = try? paquet(fichiers) else { return false }
        vider(groupe)
        for (index, morceau) in morceaux(paquet).enumerated() {
            let element: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: String(index),
                kSecAttrAccessGroup: groupe, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecAttrSynchronizable: false, kSecValueData: morceau,
            ]
            guard SecItemAdd(element as CFDictionary, nil) == errSecSuccess else { vider(groupe); return false }
        }
        return true
    }

    /// Fichiers déposés (app), puis trousseau vidé : un partage n'est reçu qu'une fois.
    public static func retirer() -> [IrisFichierPartage] {
        guard let groupe else { return [] }
        defer { vider(groupe) }
        var morceaux: [Data] = []
        while true {
            let requete: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: String(morceaux.count),
                kSecAttrAccessGroup: groupe, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
            ]
            var resultat: CFTypeRef?
            guard SecItemCopyMatching(requete as CFDictionary, &resultat) == errSecSuccess, let morceau = resultat as? Data else { break }
            morceaux.append(morceau)
        }
        return (try? fichiers(Data(morceaux.joined()))) ?? []
    }

    /// Photo réduite à `coteImage` pixels au plus, à l'endroit, en JPEG sans métadonnées (ni lieu).
    public static func reduire(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: coteImage,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let sortie = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(sortie, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? sortie as Data : nil
    }

    /// Groupe du trousseau commun à l'app et à l'extension (préfixe de l'équipe compris).
    private static var groupe: String? {
        Bundle.main.object(forInfoDictionaryKey: "IrisGroupeTrousseau") as? String
    }

    private static func vider(_ groupe: String) {
        let requete: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccessGroup: groupe]
        SecItemDelete(requete as CFDictionary)
    }

    /// Fichiers mis en un seul bloc ; les limites (nombre, taille) appliquées.
    static func paquet(_ fichiers: [IrisFichierPartage]) throws -> Data {
        var total = 0
        let gardes = fichiers.prefix(nombreMax).map { fichier in
            total += fichier.data.count
            var garde = fichier
            if total > tailleMax { garde.data = Data() }
            return garde
        }
        return try PropertyListEncoder().encode(gardes)
    }

    static func fichiers(_ paquet: Data) throws -> [IrisFichierPartage] {
        try PropertyListDecoder().decode([IrisFichierPartage].self, from: paquet)
    }

    /// Bloc coupé en morceaux d'un Mo (un élément du trousseau chacun).
    static func morceaux(_ data: Data, taille: Int = tailleMorceau) -> [Data] {
        stride(from: 0, to: max(data.count, 1), by: taille).map { data.subdata(in: $0..<min($0 + taille, data.count)) }
    }
}

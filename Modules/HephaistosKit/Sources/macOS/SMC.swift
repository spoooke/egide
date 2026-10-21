import Foundation
import IOKit

/// Lecture des clés d'AppleSMC, sans mot de passe administrateur.
/// La structure d'échange fait 80 octets, remplie par positions pour ne pas dépendre de l'alignement Swift.
final class SMC {
    /// Clé déjà interrogée : son type et sa taille sont gardés, une lecture ne coûte plus qu'un appel.
    struct Cle {
        let nom: String
        let type: String
        let taille: Int
    }

    private var connexion: io_connect_t = 0
    private enum Position { static let cle = 0, taille = 28, type = 32, resultat = 40, commande = 42, index = 44, octets = 48 }
    private enum Commande { static let lireOctets: UInt8 = 5, lireCleParIndex: UInt8 = 8, lireInfos: UInt8 = 9 }

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connexion) == kIOReturnSuccess else { return nil }
    }

    deinit { IOServiceClose(connexion) }

    private func appel(_ entree: [UInt8]) -> [UInt8]? {
        var sortie = [UInt8](repeating: 0, count: 80)
        var taille = 80
        let retour = IOConnectCallStructMethod(connexion, 2, entree, 80, &sortie, &taille)
        guard retour == kIOReturnSuccess, sortie[Position.resultat] == 0 else { return nil }
        return sortie
    }

    private func ecrire(_ valeur: UInt32, dans tampon: inout [UInt8], a position: Int) {
        withUnsafeBytes(of: valeur) { tampon.replaceSubrange(position..<position + 4, with: $0) }
    }

    private func lire32(_ tampon: [UInt8], a position: Int) -> UInt32 {
        tampon[position..<position + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    static func code(_ cle: String) -> UInt32 { cle.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    static func texte(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8(code >> $0 & 0xff) }, encoding: .ascii) ?? "????"
    }

    /// Type et taille d'une clé (nil si elle n'existe pas ou dépasse 32 octets).
    func cle(_ nom: String) -> Cle? {
        var demande = [UInt8](repeating: 0, count: 80)
        ecrire(SMC.code(nom), dans: &demande, a: Position.cle)
        demande[Position.commande] = Commande.lireInfos
        guard let infos = appel(demande) else { return nil }
        let taille = Int(lire32(infos, a: Position.taille))
        guard taille <= 32 else { return nil }
        return Cle(nom: nom, type: SMC.texte(lire32(infos, a: Position.type)), taille: taille)
    }

    func nombre(_ cle: Cle) -> Double? {
        var demande = [UInt8](repeating: 0, count: 80)
        ecrire(SMC.code(cle.nom), dans: &demande, a: Position.cle)
        ecrire(UInt32(cle.taille), dans: &demande, a: Position.taille)
        demande[Position.commande] = Commande.lireOctets
        guard let valeur = appel(demande) else { return nil }
        return SMC.nombre(type: cle.type, octets: Array(valeur[Position.octets..<Position.octets + cle.taille]))
    }

    func nombre(_ nom: String) -> Double? { cle(nom).flatMap(nombre) }

    /// Valeur numérique d'une clé (les « flt » sont en petit-boutiste sur Apple Silicon, les entiers en gros-boutiste).
    static func nombre(type: String, octets o: [UInt8]) -> Double? {
        switch type {
        case "flt " where o.count == 4: Double(o.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })
        case "ui8 " where o.count == 1: Double(o[0])
        case "ui16" where o.count == 2: Double(UInt16(o[0]) << 8 | UInt16(o[1]))
        case "ui32" where o.count == 4: Double(o.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case "sp78" where o.count == 2: Double(Int16(bitPattern: UInt16(o[0]) << 8 | UInt16(o[1]))) / 256
        default: nil
        }
    }

    func toutesLesCles() -> [String] {
        guard let total = nombre("#KEY") else { return [] }
        return (0..<UInt32(total)).compactMap { index in
            var demande = [UInt8](repeating: 0, count: 80)
            demande[Position.commande] = Commande.lireCleParIndex
            ecrire(index, dans: &demande, a: Position.index)
            return appel(demande).map { SMC.texte(lire32($0, a: Position.cle)) }
        }
    }
}

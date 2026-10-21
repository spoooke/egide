// Héphaïstos · phase 0 : preuve de lecture des capteurs du Mac, sans mot de passe administrateur.
// Usage : swiftc -O scripts/sondes-temperature.swift -o /tmp/sondes && /tmp/sondes [--tout]
//   --tout : liste aussi toutes les clés SMC de température (T…) et de ventilateur (F…), pas seulement le résumé.
// Deux sources : capteurs HID (IOHIDEventSystemClient, usage « température ») et clés SMC (AppleSMC via IOKit).
import Foundation
import IOKit

// MARK: - Capteurs HID (fonctions privées d'IOKit, déclarées à la main)

@_silgen_name("IOHIDEventSystemClientCreate")
func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> UnsafeMutableRawPointer?
@_silgen_name("IOHIDEventSystemClientSetMatching")
func IOHIDEventSystemClientSetMatching(_ client: UnsafeMutableRawPointer, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
func IOHIDEventSystemClientCopyServices(_ client: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
@_silgen_name("IOHIDServiceClientCopyProperty")
func IOHIDServiceClientCopyProperty(_ service: UnsafeRawPointer, _ key: CFString) -> UnsafeMutableRawPointer?
@_silgen_name("IOHIDServiceClientCopyEvent")
func IOHIDServiceClientCopyEvent(_ service: UnsafeRawPointer, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> UnsafeMutableRawPointer?
@_silgen_name("IOHIDEventGetFloatValue")
func IOHIDEventGetFloatValue(_ event: UnsafeRawPointer, _ field: Int32) -> Double

let kHIDPageAppleVendor = 0xff00
let kHIDUsageTemperatureSensor = 5
let kIOHIDEventTypeTemperature: Int64 = 15

func lireCapteursHID() -> [(nom: String, degres: Double)] {
    guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return [] }
    defer { Unmanaged<AnyObject>.fromOpaque(client).release() }
    let filtre = ["PrimaryUsagePage": kHIDPageAppleVendor, "PrimaryUsage": kHIDUsageTemperatureSensor] as CFDictionary
    _ = IOHIDEventSystemClientSetMatching(client, filtre)
    guard let brut = IOHIDEventSystemClientCopyServices(client) else { return [] }
    let services = Unmanaged<CFArray>.fromOpaque(brut).takeRetainedValue() as [AnyObject]
    var mesures: [(String, Double)] = []
    for service in services {
        let pointeur = UnsafeRawPointer(Unmanaged.passUnretained(service).toOpaque())
        guard let nomBrut = IOHIDServiceClientCopyProperty(pointeur, "Product" as CFString),
              let nom = Unmanaged<AnyObject>.fromOpaque(nomBrut).takeRetainedValue() as? String,
              let evenement = IOHIDServiceClientCopyEvent(pointeur, kIOHIDEventTypeTemperature, 0, 0) else { continue }
        let degres = IOHIDEventGetFloatValue(evenement, Int32(kIOHIDEventTypeTemperature << 16))
        Unmanaged<AnyObject>.fromOpaque(evenement).release()
        mesures.append((nom, degres))
    }
    return mesures.sorted { $0.0 < $1.0 }
}

// MARK: - SMC (structure de 80 octets remplie par positions, pour ne pas dépendre de l'alignement Swift)

final class SMC {
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

    /// Valeur brute d'une clé : son type (« flt  », « ui8  »…) et ses octets.
    func lire(_ cle: String) -> (type: String, octets: [UInt8])? {
        var demande = [UInt8](repeating: 0, count: 80)
        ecrire(SMC.code(cle), dans: &demande, a: Position.cle)
        demande[Position.commande] = Commande.lireInfos
        guard let infos = appel(demande) else { return nil }
        let taille = Int(lire32(infos, a: Position.taille))
        let type = SMC.texte(lire32(infos, a: Position.type))
        ecrire(UInt32(taille), dans: &demande, a: Position.taille)
        demande[Position.commande] = Commande.lireOctets
        guard taille <= 32, let valeur = appel(demande) else { return nil }
        return (type, Array(valeur[Position.octets..<Position.octets + taille]))
    }

    /// Valeur numérique d'une clé (les « flt » sont en petit-boutiste sur Apple Silicon).
    func nombre(_ cle: String) -> Double? {
        guard let (type, o) = lire(cle) else { return nil }
        switch type {
        case "flt " where o.count == 4: return Double(o.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })
        case "ui8 " where o.count == 1: return Double(o[0])
        case "ui16" where o.count == 2: return Double(UInt16(o[0]) << 8 | UInt16(o[1]))
        case "ui32" where o.count == 4: return Double(o.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case "sp78" where o.count == 2: return Double(Int16(o[0]) << 8 | Int16(o[1])) / 256
        default: return nil
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

// MARK: - Affichage

func ligne(_ nom: String, _ valeur: Double, _ unite: String) {
    print("  " + nom.padding(toLength: 34, withPad: " ", startingAt: 0) + String(format: "%7.1f ", valeur) + unite)
}
func modele() -> String {
    var taille = 0
    sysctlbyname("hw.model", nil, &taille, nil, 0)
    var tampon = [CChar](repeating: 0, count: taille)
    sysctlbyname("hw.model", &tampon, &taille, nil, 0)
    return String(cString: tampon)
}

let tout = CommandLine.arguments.contains("--tout")
print("Mac : \(modele()), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n")

let hid = lireCapteursHID()
print("Capteurs HID (\(hid.count)) :")
for (nom, degres) in hid { ligne(nom, degres, "°C") }
let plausibles = hid.map(\.degres).filter { $0 > 0 && $0 < 130 }
if let max = plausibles.max() {
    print(String(format: "  → le plus chaud : %.1f °C, moyenne : %.1f °C", max, plausibles.reduce(0, +) / Double(plausibles.count)))
}

guard let smc = SMC() else {
    print("\nSMC : ouverture d'AppleSMC refusée.")
    exit(1)
}
let cles = smc.toutesLesCles()
let temperatures = cles.filter { $0.hasPrefix("T") }.compactMap { cle in smc.nombre(cle).map { (cle, $0) } }.filter { $0.1 > 0 && $0.1 < 130 }
print("\nSMC : \(cles.count) clés, dont \(temperatures.count) températures plausibles.")
if let max = temperatures.max(by: { $0.1 < $1.1 }) {
    print(String(format: "  → la plus chaude : %@ à %.1f °C", max.0, max.1))
}
if tout {
    for (cle, degres) in temperatures { ligne(cle, degres, "°C") }
    print("\nClés de ventilateur (F…) :")
    for cle in cles where cle.hasPrefix("F") {
        if let valeur = smc.nombre(cle) { ligne(cle, valeur, "") }
    }
}

let ventilateurs = Int(smc.nombre("FNum") ?? 0)
print("\nVentilateurs : \(ventilateurs)")
for i in 0..<ventilateurs {
    if let actuel = smc.nombre("F\(i)Ac") {
        let mini = smc.nombre("F\(i)Mn") ?? 0, maxi = smc.nombre("F\(i)Mx") ?? 0
        print(String(format: "  ventilateur %d : %.0f tr/min (mini %.0f, maxi %.0f)", i, actuel, mini, maxi))
    }
}

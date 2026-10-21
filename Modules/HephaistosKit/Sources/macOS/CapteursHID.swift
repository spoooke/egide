import Foundation
import IOKit

// Fonctions privées d'IOKit, déclarées à la main.
@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> UnsafeMutableRawPointer?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: UnsafeMutableRawPointer, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: UnsafeRawPointer, _ key: CFString) -> UnsafeMutableRawPointer?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: UnsafeRawPointer, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> UnsafeMutableRawPointer?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: UnsafeRawPointer, _ field: Int32) -> Double

/// Capteurs de température HID (IOHIDEventSystemClient, page Apple 0xff00, usage 5), sans mot de passe administrateur.
/// La liste des capteurs est dressée une fois ; chaque lecture ne demande ensuite qu'un événement par capteur.
final class CapteursHID {
    private static let evenementTemperature: Int64 = 15

    private let client: AnyObject?
    private let services: [(nom: String, service: AnyObject)]

    init() {
        guard let brutClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
            client = nil
            services = []
            return
        }
        client = Unmanaged<AnyObject>.fromOpaque(brutClient).takeRetainedValue()
        _ = IOHIDEventSystemClientSetMatching(brutClient, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let brut = IOHIDEventSystemClientCopyServices(brutClient) else {
            services = []
            return
        }
        services = (Unmanaged<CFArray>.fromOpaque(brut).takeRetainedValue() as [AnyObject]).compactMap { service in
            let pointeur = UnsafeRawPointer(Unmanaged.passUnretained(service).toOpaque())
            guard let nomBrut = IOHIDServiceClientCopyProperty(pointeur, "Product" as CFString),
                  let nom = Unmanaged<AnyObject>.fromOpaque(nomBrut).takeRetainedValue() as? String else { return nil }
            return (nom, service)
        }
        .sorted { $0.nom < $1.nom }
    }

    private func degres(_ service: AnyObject) -> Double? {
        let pointeur = UnsafeRawPointer(Unmanaged.passUnretained(service).toOpaque())
        guard let evenement = IOHIDServiceClientCopyEvent(pointeur, Self.evenementTemperature, 0, 0) else { return nil }
        defer { Unmanaged<AnyObject>.fromOpaque(evenement).release() }
        return IOHIDEventGetFloatValue(evenement, Int32(Self.evenementTemperature << 16))
    }

    /// Tous les capteurs, triés par nom (plusieurs capteurs peuvent porter le même nom).
    func tous() -> [(nom: String, degres: Double)] {
        services.compactMap { capteur in degres(capteur.service).map { (capteur.nom, $0) } }
    }

    /// Premier capteur de ce nom.
    func lire(_ nom: String) -> Double? {
        services.first { $0.nom == nom }.flatMap { degres($0.service) }
    }
}

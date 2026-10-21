import Foundation
import Security
import UIKit

struct PairedMac: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var publicKey: Data
    var hosts: [String]
    var port: UInt16
    var lastConnected: Date?

    var fingerprint: String { DeviceIdentity.fingerprint(of: publicKey) }
}

/// Paired Macs (public data only) + this iPhone's identity key (Keychain, this device only).
final class MacStore: ObservableObject {
    @Published private(set) var macs: [PairedMac] = []
    // Préfixe « hermes. » : les préférences d'Égide sont partagées entre les modules.
    private let defaultsKey = "hermes.pairedMacs"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let list = try? JSONDecoder().decode([PairedMac].self, from: data) {
            macs = list
        }
    }

    func upsert(_ mac: PairedMac) {
        if let i = macs.firstIndex(where: { $0.publicKey == mac.publicKey }) {
            var updated = mac
            updated.id = macs[i].id
            macs[i] = updated
        } else {
            macs.append(mac)
        }
        save()
    }

    func remove(_ mac: PairedMac) {
        macs.removeAll { $0.id == mac.id }
        save()
    }

    func markConnected(_ mac: PairedMac, via host: String?) {
        guard let i = macs.firstIndex(where: { $0.id == mac.id }) else { return }
        macs[i].lastConnected = Date()
        if let host, !macs[i].hosts.contains(host) { macs[i].hosts.insert(host, at: 0) }
        save()
    }

    func addHost(_ host: String, to mac: PairedMac) {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, let i = macs.firstIndex(where: { $0.id == mac.id }), !macs[i].hosts.contains(h) else { return }
        macs[i].hosts.append(h)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(macs) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    // MARK: Identity

    /// Clé propre à Égide : nouvel appairage obligatoire (la clé de l'ancienne app reste liée à elle).
    private static let keychainService = "com.spoooke.egide.hermes.identity"

    /// Encrypted Secure Enclave handle (or software key on the simulator).
    static func identityBlob() throws -> Data {
        if let existing = keychainRead() { return existing }
        let identity = try DeviceIdentity.create(requireBiometry: true)
        try keychainWrite(identity.persistentData)
        return identity.persistentData
    }

    static var identityPublicKey: Data? {
        guard let blob = keychainRead(), let id = try? DeviceIdentity.restore(from: blob) else { return nil }
        return id.publicKeyData
    }

    static var identityIsHardwareBacked: Bool { keychainRead()?.first == 1 }

    private static func keychainRead() -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func keychainWrite(_ data: Data) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService] as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static var deviceName: String { UIDevice.current.name }
}

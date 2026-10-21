import Foundation
import CryptoKit
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// Long‑term signing identity of a device (P‑256).
/// Lives in the Secure Enclave when available: the private key never leaves the chip.
struct DeviceIdentity {
    private enum Backing {
        case enclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)
    }

    private let backing: Backing

    var publicKey: P256.Signing.PublicKey {
        switch backing {
        case .enclave(let k): return k.publicKey
        case .software(let k): return k.publicKey
        }
    }

    var publicKeyData: Data { publicKey.x963Representation }
    var isHardwareBacked: Bool { if case .enclave = backing { return true } else { return false } }

    /// Opaque blob to persist. For an enclave key it is an encrypted handle usable only on this device.
    var persistentData: Data {
        switch backing {
        case .enclave(let k): return Data([1]) + k.dataRepresentation
        case .software(let k): return Data([0]) + k.rawRepresentation
        }
    }

    func sign(_ message: Data) throws -> Data {
        switch backing {
        case .enclave(let k): return try k.signature(for: message).rawRepresentation
        case .software(let k): return try k.signature(for: message).rawRepresentation
        }
    }

    /// - Parameter requireBiometry: when true (iPhone), every signature requires Face ID / Touch ID.
    static func create(requireBiometry: Bool) throws -> DeviceIdentity {
        // The simulated enclave hangs on biometric access control: software key there only.
        #if targetEnvironment(simulator)
        let useEnclave = false
        #else
        let useEnclave = SecureEnclave.isAvailable
        #endif
        if useEnclave {
            var flags: SecAccessControlCreateFlags = [.privateKeyUsage]
            if requireBiometry { flags.insert(.biometryCurrentSet) }
            var error: Unmanaged<CFError>?
            // The Mac must keep answering while its screen is locked; the iPhone key is usable only when unlocked.
            let protection = requireBiometry ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            if let access = SecAccessControlCreateWithFlags(nil, protection, flags, &error),
               let key = try? SecureEnclave.P256.Signing.PrivateKey(accessControl: access) {
                return DeviceIdentity(backing: .enclave(key))
            }
        }
        return DeviceIdentity(backing: .software(P256.Signing.PrivateKey()))
    }

    /// - Parameter context: an already‑evaluated LAContext (iPhone) so the enclave does not prompt a second time.
    static func restore(from data: Data, context: AnyObject? = nil) throws -> DeviceIdentity {
        guard let tag = data.first else { throw HermesError.badMessage }
        let body = Data(data.dropFirst())
        switch tag {
        case 1:
            #if canImport(LocalAuthentication)
            if let context = context as? LAContext {
                return DeviceIdentity(backing: .enclave(try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: body, authenticationContext: context)))
            }
            #endif
            return DeviceIdentity(backing: .enclave(try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: body)))
        case 0:
            return DeviceIdentity(backing: .software(try P256.Signing.PrivateKey(rawRepresentation: body)))
        default:
            throw HermesError.badMessage
        }
    }

    static func verify(signature: Data, of message: Data, publicKey: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return key.isValidSignature(sig, for: message)
    }

    /// Short human‑readable fingerprint, e.g. "3F9A-01BC-77D2".
    static func fingerprint(of publicKey: Data) -> String {
        let hex = SHA256.hash(data: publicKey).prefix(6).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { i -> String in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[start..<hex.index(start, offsetBy: 4)])
        }.joined(separator: "-")
    }
}

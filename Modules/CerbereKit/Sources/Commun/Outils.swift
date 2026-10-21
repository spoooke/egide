import Foundation

/// Lancement d'un outil du système (codesign, otool, strings, bsdtar, PowerShell…), jamais d'un fichier audité.
/// Le fichier audité n'est qu'un argument : il est lu par l'outil, pas lancé. Environnement réduit, dossier de
/// travail hors de la quarantaine, durée et taille de sortie bornées, arrêt possible.
enum Outil {
    struct Resultat: Sendable {
        var code: Int32
        var sortie: String
        var erreur: String
        /// L'outil a été arrêté parce qu'il dépassait la durée permise.
        var horsDelai = false

        var tout: String { sortie + (sortie.isEmpty || erreur.isEmpty ? "" : "\n") + erreur }
    }

    static var environnement: [String: String] { Plateforme.environnement }

    /// `ajouts` : variables passées en plus de l'environnement réduit (un chemin donné à PowerShell, par exemple :
    /// jamais dans le texte de la commande).
    static func lancer(_ outil: String, _ arguments: [String], annulation: Annulation? = nil, delai: TimeInterval = 120,
                       max: Int = 16_000_000, ajouts: [String: String] = [:]) -> Resultat {
        guard annulation?.demandee != true else { return Resultat(code: -1, sortie: "", erreur: "annulé") }
        let processus = Process()
        processus.executableURL = URL(fileURLWithPath: outil)
        processus.arguments = arguments
        processus.environment = environnement.merging(ajouts) { $1 }
        processus.currentDirectoryURL = FileManager.default.temporaryDirectory
        processus.standardInput = FileHandle.nullDevice
        let sortie = Pipe(), erreur = Pipe()
        processus.standardOutput = sortie
        processus.standardError = erreur
        do { try processus.run() } catch { return Resultat(code: -1, sortie: "", erreur: "\(error)") }
        annulation?.suivre(processus)
        defer { annulation?.oublier(processus) }
        let depasse = Drapeau()
        let garde = DispatchWorkItem {
            guard processus.isRunning else { return }
            depasse.lever()
            processus.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delai, execute: garde)
        // Les deux tuyaux sont vidés en même temps (un tuyau plein bloquerait l'outil) ; au-delà de `max`, le reste est jeté.
        let lus = Tampons()
        let groupe = DispatchGroup()
        for (i, tuyau) in [sortie, erreur].enumerated() {
            groupe.enter()
            DispatchQueue.global().async {
                var donnees = Data()
                while let morceau = try? tuyau.fileHandleForReading.read(upToCount: 1 << 16), !morceau.isEmpty {
                    if donnees.count < max { donnees.append(morceau.prefix(max - donnees.count)) }
                }
                lus.ranger(i, donnees)
                groupe.leave()
            }
        }
        groupe.wait()
        processus.waitUntilExit()
        garde.cancel()
        return Resultat(code: processus.terminationStatus, sortie: String(decoding: lus.lire(0), as: UTF8.self),
                        erreur: String(decoding: lus.lire(1), as: UTF8.self), horsDelai: depasse.leve)
    }
}

private final class Tampons: @unchecked Sendable {
    private var cases = [Data(), Data()]
    private let verrou = NSLock()

    func ranger(_ i: Int, _ d: Data) {
        verrou.lock()
        cases[i] = d
        verrou.unlock()
    }

    func lire(_ i: Int) -> Data {
        verrou.lock()
        defer { verrou.unlock() }
        return cases[i]
    }
}

final class Drapeau: @unchecked Sendable {
    private var etat = false
    private let verrou = NSLock()

    func lever() {
        verrou.lock()
        etat = true
        verrou.unlock()
    }

    var leve: Bool {
        verrou.lock()
        defer { verrou.unlock() }
        return etat
    }
}

import UIKit
import UniformTypeIdentifiers

/// Extension de partage « Égide » :
/// - une photo ou un PDF (Photos, Fichiers) va à Iris : fichiers déposés par IrisColis, puis egide://iris/partage ;
///   Iris les cadre ou les range, et le mail ne part qu'après un appui sur Envoyer ;
/// - le lien d'une page (Safari, GitHub…) va à Cerbère (egide://cerbere/audit?lien=…) : Égide montre le lien,
///   et la demande ne part au Mac qu'après « Envoyer au Mac ».
/// Elle ne contacte rien et n'envoie rien.
final class PartageViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task {
            let fichiers = await fichiersPartages()
            if !fichiers.isEmpty {
                IrisColis.deposer(fichiers)
                ouvrir(IrisColis.lien)
            } else if let lien = await lienPartage(), let url = Self.lienEgide(lien) {
                ouvrir(url)
            }
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// egide://cerbere/audit?lien=<lien encodé>. Seul un lien http(s) passe ; Cerbère le contrôle ensuite.
    static func lienEgide(_ lien: URL) -> URL? {
        guard ["http", "https"].contains(lien.scheme?.lowercased() ?? ""), lien.absoluteString.count <= 2000 else { return nil }
        var parties = URLComponents()
        parties.scheme = "egide"
        parties.host = "cerbere"
        parties.path = "/audit"
        parties.queryItems = [URLQueryItem(name: "lien", value: lien.absoluteString)]
        return parties.url
    }

    /// Fichiers partagés (photos, PDF, autres fichiers), dans l'ordre. Seuls les photos et les PDF sont lus ;
    /// un autre fichier passe sans contenu, Iris l'écarte et le dit. Rien si un lien web est partagé.
    private func fichiersPartages() async -> [IrisFichierPartage] {
        let pieces = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        // Un lien web (Safari, GitHub…) va à Cerbère.
        let lienWeb = pieces.contains { $0.registeredContentTypes.contains { $0.conforms(to: .url) && !$0.conforms(to: .fileURL) } }
        guard !lienWeb else { return [] }
        var fichiers: [IrisFichierPartage] = []
        for piece in pieces.prefix(IrisColis.nombreMax) {
            let types = piece.registeredContentTypes
            if let type = types.first(where: { $0.conforms(to: .pdf) }) ?? types.first(where: { $0.conforms(to: .image) }) {
                guard let (data, nomFichier) = await Self.contenu(piece, type: type) else { continue }
                let nom = piece.suggestedName ?? nomFichier
                if type.conforms(to: .pdf) {
                    fichiers.append(IrisFichierPartage(type: type.identifier, nom: nom, data: data))
                } else {
                    // Réduite ici à la taille que garde Iris : le passage reste léger, et le lieu est retiré.
                    let jpeg = IrisColis.reduire(data)
                    fichiers.append(IrisFichierPartage(type: jpeg == nil ? type.identifier : UTType.jpeg.identifier,
                                                       nom: nom, data: jpeg ?? data))
                }
            } else if let type = types.first(where: { !$0.conforms(to: .text) && !$0.conforms(to: .url) }) {
                // Autre fichier (un texte peut être un lien pour Cerbère : il n'est pas pris ici).
                let nom = await Self.nomFichier(piece, type: type)
                fichiers.append(IrisFichierPartage(type: type.identifier, nom: piece.suggestedName ?? nom ?? "", data: Data()))
            }
        }
        return fichiers
    }

    /// Contenu et nom du fichier, lus pendant que la copie temporaire d'iOS existe encore.
    private static func contenu(_ piece: NSItemProvider, type: UTType) async -> (Data, String)? {
        await withCheckedContinuation { suite in
            _ = piece.loadFileRepresentation(for: type) { url, _, _ in
                guard let url, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return suite.resume(returning: nil) }
                suite.resume(returning: (data, url.lastPathComponent))
            }
        }
    }

    /// Nom seul d'un fichier écarté (son contenu n'est pas lu).
    private static func nomFichier(_ piece: NSItemProvider, type: UTType) async -> String? {
        await withCheckedContinuation { suite in
            _ = piece.loadFileRepresentation(for: type) { url, _, _ in suite.resume(returning: url?.lastPathComponent) }
        }
    }

    /// Premier lien web parmi les éléments partagés (une page, ou un texte qui n'est qu'un lien).
    private func lienPartage() async -> URL? {
        let pieces = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for piece in pieces where piece.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await piece.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL { return url }
        }
        for piece in pieces where piece.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let texte = try? await piece.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
               let url = URL(string: texte.trimmingCharacters(in: .whitespacesAndNewlines)), url.host() != nil { return url }
        }
        return nil
    }

    /// Une extension n'a pas le droit d'appeler `UIApplication` (API réservée aux apps) : l'app hôte est retrouvée
    /// dans la chaîne des répondeurs, et son `open(_:options:completionHandler:)` est appelé par son nom.
    /// Usage toléré mais non garanti par Apple : s'il cesse de marcher, rien ne s'ouvre et rien n'est envoyé.
    private func ouvrir(_ url: URL) {
        let selecteur = NSSelectorFromString("openURL:options:completionHandler:")
        guard let classe = NSClassFromString("UIApplication") else { return }
        var repondeur: UIResponder? = self
        while let courant = repondeur {
            if courant.isKind(of: classe), courant.responds(to: selecteur) {
                typealias Ouvrir = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                unsafeBitCast(courant.method(for: selecteur), to: Ouvrir.self)(courant, selecteur, url as NSURL, [:], nil)
                return
            }
            repondeur = courant.next
        }
    }
}

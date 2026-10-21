import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Ce que devient un fichier partagé vers Iris.
public enum IrisDestination: Equatable, Sendable {
    /// Image : cadrage, puis PDF, comme une photo importée.
    case cadrage
    /// PDF : rangé tel quel dans Documents/Iris.
    case rangement
    /// Autre type, ou fichier vide ou trop gros : écarté.
    case refus
}

/// Fichiers partagés triés : images à cadrer, PDF à ranger, noms des fichiers écartés.
public struct IrisTriPartage: Equatable, Sendable {
    public var images: [Data] = []
    public var pdfs: [IrisFichierPartage] = []
    public var refuses: [String] = []
}

public enum IrisPartage {
    public static func destination(_ fichier: IrisFichierPartage) -> IrisDestination {
        guard !fichier.data.isEmpty, let type = UTType(fichier.type) else { return .refus }
        if type.conforms(to: .pdf) {
            guard let source = CGDataProvider(data: fichier.data as CFData), let pdf = CGPDFDocument(source),
                  pdf.numberOfPages > 0 else { return .refus }
            return .rangement
        }
        return type.conforms(to: .image) ? .cadrage : .refus
    }

    public static func trier(_ fichiers: [IrisFichierPartage]) -> IrisTriPartage {
        var tri = IrisTriPartage()
        for fichier in fichiers {
            switch destination(fichier) {
            case .cadrage: tri.images.append(fichier.data)
            case .rangement: tri.pdfs.append(fichier)
            case .refus: tri.refuses.append(fichier.nom.isEmpty ? "Fichier sans nom" : fichier.nom)
            }
        }
        return tri
    }
}

extension IrisNom {
    /// Nom d'un PDF partagé : celui du fichier, sans extension ni caractère gênant, 80 caractères au plus ;
    /// « Document 2026-10-16 » s'il n'en reste rien ; « (2) » si le nom est pris.
    public static func partage(_ nomFichier: String, le date: Date, calendrier: Calendar = .current, pris: Set<String> = []) -> String {
        var base = nomFichier
        if (base as NSString).pathExtension.lowercased() == "pdf" { base = (base as NSString).deletingPathExtension }
        base = base.map { $0.isWhitespace || $0.isNewline || "/\\:".contains($0) || $0.asciiValue.map { $0 < 32 } == true ? " " : String($0) }
            .joined().split(separator: " ").joined(separator: " ")
        while base.hasPrefix(".") { base.removeFirst() }
        base = String(base.prefix(80)).trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return nom(.document, le: date, calendrier: calendrier, pris: pris) }
        return libre(base, pris: pris)
    }
}

extension IrisScans {
    /// Range un PDF partagé tel quel, sous son nom (libre).
    public func ranger(_ fichier: IrisFichierPartage, le date: Date = .now) throws -> IrisScan {
        guard IrisPartage.destination(fichier) == .rangement else { throw IrisErreur.pdfImpossible }
        try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        let nom = IrisNom.partage(fichier.nom, le: date, pris: Set(liste().map(\.nom)))
        let url = dossier.appending(path: nom + ".pdf")
        try fichier.data.write(to: url, options: [.atomic, .completeFileProtection])
        return IrisScan(url: url, date: date)
    }
}

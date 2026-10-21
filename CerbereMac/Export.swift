import AppKit
import CerbereKit

/// Export d'un rapport : Markdown et JSON (les mêmes fichiers que ceux du dossier de l'audit), ou PDF.
@MainActor
enum Export {
    enum Format {
        case markdown, json, pdf

        var suffixe: String {
            switch self {
            case .markdown: "md"
            case .json: "json"
            case .pdf: "pdf"
            }
        }
    }

    static func ecrire(_ rapport: Rapport, _ format: Format, vers url: URL) throws {
        switch format {
        case .markdown: try Data(rapport.markdown().utf8).write(to: url, options: .atomic)
        case .json: try rapport.json().write(to: url, options: .atomic)
        case .pdf: try pdf(rapport, vers: url)
        }
    }

    /// PDF paginé (A4) : le rapport est mis en page comme un texte, puis « imprimé » dans un fichier, sans dialogue.
    /// Le contenu venu du code audité n'est que du texte : aucun lien, aucune image, rien d'actif dans le PDF.
    static func pdf(_ rapport: Rapport, vers url: URL) throws {
        let papier = NSSize(width: 595, height: 842), marge = 48.0
        let info = NSPrintInfo()
        info.paperSize = papier
        info.topMargin = marge
        info.bottomMargin = marge
        info.leftMargin = marge
        info.rightMargin = marge
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary().setObject(url, forKey: NSPrintInfo.AttributeKey.jobSavingURL.rawValue as NSString)

        let vue = NSTextView(frame: NSRect(x: 0, y: 0, width: papier.width - 2 * marge, height: 100))
        vue.appearance = NSAppearance(named: .aqua)
        vue.isEditable = false
        vue.isAutomaticLinkDetectionEnabled = false
        vue.backgroundColor = .white
        vue.textContainerInset = .zero
        vue.textStorage?.setAttributedString(texte(rapport))
        if let conteneur = vue.textContainer { vue.layoutManager?.ensureLayout(for: conteneur) }
        vue.sizeToFit()

        let impression = NSPrintOperation(view: vue, printInfo: info)
        impression.showsPrintPanel = false
        impression.showsProgressPanel = false
        guard impression.run() else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Même ordre que le Markdown : verdict, résumé, explication simple, constats par gravité, écartés, domaines, non analysé, bilan.
    static func texte(_ r: Rapport) -> NSAttributedString {
        let t = NSMutableAttributedString()
        let encre = NSColor.black, gris = NSColor(white: 0.35, alpha: 1)
        func style(avant: CGFloat = 0, apres: CGFloat = 4, retrait: CGFloat = 0) -> NSParagraphStyle {
            let s = NSMutableParagraphStyle()
            s.paragraphSpacingBefore = avant
            s.paragraphSpacing = apres
            s.firstLineHeadIndent = retrait
            s.headIndent = retrait
            return s
        }
        func ajouter(_ s: String, _ police: NSFont, _ couleur: NSColor = encre, _ paragraphe: NSParagraphStyle = style(), fond: NSColor? = nil) {
            var attributs: [NSAttributedString.Key: Any] = [.font: police, .foregroundColor: couleur, .paragraphStyle: paragraphe]
            if let fond { attributs[.backgroundColor] = fond }
            t.append(NSAttributedString(string: s.montrable + "\n", attributes: attributs))
        }
        let corps = NSFont.systemFont(ofSize: 10), petit = NSFont.systemFont(ofSize: 8.5), fixe = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .regular)
        func titre(_ s: String) { ajouter(s, .boldSystemFont(ofSize: 13), encre, style(avant: 12, apres: 6)) }

        ajouter("Cerbère — \(r.verdict.titre)", .boldSystemFont(ofSize: 20), encre, style(apres: 8))
        ajouter(r.cible.source, fixe)
        var precisions = [r.date.formatted(date: .long, time: .shortened)]
        if let commit = r.cible.commit { precisions.append("commit \(commit)") }
        if let empreinte = r.cible.empreinte { precisions.append("SHA-256 \(empreinte)") }
        precisions.append("\(r.fichiersAnalyses) fichiers analysés")
        precisions.append(r.couches.ia ? "règles automatiques + lecture par IA" : "règles automatiques seules")
        ajouter(precisions.joined(separator: " · "), petit, gris, style(apres: 8))
        ajouter(r.resume, corps, encre, style(apres: 6))
        ajouter("Un audit statique baisse le risque, il ne prouve pas qu'un logiciel est sain.", petit, gris)
        if let n = r.neophyte {
            titre("Expliqué simplement")
            ajouter(n.enBref, corps, encre, style(apres: 6))
            if !n.aSavoir.isEmpty {
                ajouter("À savoir", .boldSystemFont(ofSize: 10), encre, style(avant: 4, apres: 2))
                for p in n.aSavoir { ajouter("• \(p)", corps, encre, style(apres: 2, retrait: 8)) }
            }
            if !n.queFaire.isEmpty {
                ajouter("Que faire", .boldSystemFont(ofSize: 10), encre, style(avant: 4, apres: 2))
                for p in n.queFaire { ajouter("• \(p)", corps, encre, style(apres: 2, retrait: 8)) }
            }
        }

        func constat(_ c: Constat) {
            ajouter("\(c.id) · \(c.titre)", .boldSystemFont(ofSize: 10.5), encre, style(avant: 8, apres: 2))
            ajouter("\(c.gravite.titre) · \(c.statut == .confirme ? "Vu dans le code" : "Suspect") · \(c.categorie.titre) · \(c.origine == .ia ? "lecture par IA" : "règle automatique")", petit, gris, style(apres: 2))
            ajouter(c.lieu, fixe, encre, style(apres: 3))
            ajouter(c.explication, corps)
            if let note = c.noteIA, !note.isEmpty { ajouter("Lecture par IA : \(note)", corps, gris) }
            if let v = c.verification { ajouter("Vérification ciblée : \(v.conclusion.titre) — \(v.explication) (\(v.effet))", corps) }
            if !c.extrait.isEmpty { ajouter(c.extrait, fixe, encre, style(apres: 6, retrait: 8), fond: NSColor(white: 0.94, alpha: 1)) }
        }
        let tries = r.constatsTries
        for gravite in Gravite.allCases {
            let lot = tries.filter { $0.gravite == gravite && !$0.ecarte }
            guard !lot.isEmpty else { continue }
            titre("\(gravite.titre) (\(lot.count))")
            lot.forEach(constat)
        }
        if tries.isEmpty { ajouter("Aucun constat.", corps) }
        let ecartes = tries.filter(\.ecarte)
        if !ecartes.isEmpty {
            titre("Écartés par la lecture par IA (\(ecartes.count))")
            ajouter("Indices des règles automatiques que la lecture du code a jugés sans danger. Ils ne pèsent pas sur le verdict.", petit, gris)
            for c in ecartes { ajouter("\(c.id) · \(c.titre) · \(c.lieu) — \(c.noteIA ?? "")", corps) }
        }
        let hotes = r.reseau.adresses + r.reseau.domaines
        if !hotes.isEmpty {
            titre("Domaines et adresses cités dans le code (\(hotes.count))")
            for h in hotes { ajouter("\(h.nom) — \(h.occurrences) fois (\(h.fichiers.joined(separator: ", ")))", fixe) }
        }
        if !r.nonAnalyse.isEmpty {
            titre("Non analysé (\(r.nonAnalyse.count))")
            for n in r.nonAnalyse.prefix(200) { ajouter("\(n.fichier) — \(n.raison)", fixe) }
            if r.nonAnalyse.count > 200 { ajouter("… et \(r.nonAnalyse.count - 200) autres", corps) }
        }
        if let ia = r.ia {
            titre("Bilan de la lecture par IA")
            ajouter("Modèle \(ia.modele) · \(ia.fichiersLus) fichiers lus en entier et \(ia.fichiersEnPartie) en partie sur \(ia.fichiersLisibles) · \(ia.lots - ia.lotsEchoues) lots lus sur \(ia.lots) · \(ia.citationsIntrouvables) constats rejetés (citation introuvable) · \(ia.retiresALaRelecture) retirés ou baissés à la relecture · \(ia.secretsMasques) secrets masqués avant l'envoi · tentative de manipulation relevée : \(ia.manipulation ? "oui" : "non")", corps)
        }
        return t
    }
}

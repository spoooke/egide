import Foundation

/// Audit complet : règles automatiques (couche 1, tout se passe sur le Mac, rien n'est exécuté), puis, si elle est
/// demandée, lecture par IA (couche 2, voir `LectureIA`).
public enum Audit {
    /// Audite un dépôt à partir d'un lien https (clone de quarantaine), un paquet PyPI (`pypi:<nom>`, archives ouvertes
    /// sans rien installer), ou un élément du Mac : dossier, archive, app, image disque, paquet d'installation, fichier seul.
    /// La quarantaine est supprimée à la fin, sauf si `garder` est vrai. `ia` reçoit le rapport des règles et
    /// l'inventaire tant que la quarantaine existe, et rend le rapport complété (ou le même, s'il n'y a pas d'accord).
    /// `annulation` arrête l'audit en cours (erreur `ErreurCerbere.annule`, quarantaine supprimée).
    /// `enLigne` : vérifications qui sortent du Mac (Gatekeeper, réputation), faites seulement si l'utilisateur les a demandées pour cet audit.
    public static func auditer(_ cible: String, garder: Bool = false, racine: URL = Quarantaine.racine,
                               annulation: Annulation? = nil, enLigne: EnLigne = EnLigne(), ia: ((Rapport, Inventaire) -> Rapport)? = nil,
                               suivi: (Avancement) -> Void = { _ in }) throws -> Rapport {
        try annulation?.verifier()
        suivi(Avancement(.recuperation))
        let quarantaine = try recuperer(cible, racine: racine, gatekeeper: enLigne.gatekeeper, garder: garder, annulation: annulation)
        let dossier = quarantaine.dossier
        defer { if !garder { Plateforme.supprimer(dossier) } }
        suivi(Avancement(.recuperation, lignes: ["Copie de quarantaine prête (lecture seule, rien n'est lancé)" + (quarantaine.commit.map { ", commit \($0.prefix(12))" } ?? "") + "."]))
        try annulation?.verifier()
        suivi(Avancement(.regles, "Lecture des programmes et des documents…"))
        let inventaire = Inventaire(quarantaine: quarantaine, annulation: annulation)
        try annulation?.verifier()
        suivi(Avancement(.regles, "Règles automatiques (\(inventaire.fichiers.count) fichiers)…",
                         lignes: ["Inventaire : \(inventaire.fichiers.count) fichiers, \(inventaire.textes.count) lisibles comme du texte, \(inventaire.nonAnalyse.count) non analysés."]))
        var regles = rapport(quarantaine, inventaire: inventaire, annulation: annulation)
        let notables = regles.constats.filter { $0.gravite < .info }
        suivi(Avancement(.regles, lignes: ["Règles : \(regles.constats.count) constats, dont \(notables.count) au-dessus du niveau « info »."]
                         + notables.prefix(300).map(Avancement.ligne)))
        regles.couches.gatekeeper = enLigne.gatekeeper && quarantaine.sorte != nil ? true : nil
        try annulation?.verifier()
        if let reputation = enLigne.reputation, !inventaire.empreintes.isEmpty {
            suivi(Avancement(.regles, "Réputation : envoi de \(min(inventaire.empreintes.count, Reputation.empreintesMax)) empreinte(s) à \(Reputation.domaine)…"))
            regles = reputation.completer(regles, empreintes: inventaire.empreintes, annulation: annulation)
            try annulation?.verifier()
        }
        if let vulnerabilites = enLigne.vulnerabilites {
            suivi(Avancement(.regles, "Vulnérabilités connues : \(inventaire.dependances.count) dépendance(s), noms et versions envoyés à \(Vulnerabilites.domaine)…"))
            regles = vulnerabilites.completer(regles, dependances: inventaire.dependances, annulation: annulation)
            try annulation?.verifier()
        }
        let complet = ia?(regles, inventaire) ?? regles
        try annulation?.verifier()
        return complet
    }

    /// Copie de quarantaine de la cible (lien, paquet PyPI ou élément du Mac), conteneurs imbriqués ouverts à côté.
    /// Supprimée si quelque chose échoue en route ; sinon, c'est à l'appelant de la supprimer.
    static func recuperer(_ cible: String, racine: URL = Quarantaine.racine, gatekeeper: Bool = false, garder: Bool = false,
                          annulation: Annulation? = nil) throws -> Quarantaine {
        var quarantaine: Quarantaine
        let local = URL(fileURLWithPath: (cible as NSString).expandingTildeInPath)
        if cible.hasPrefix("pypi:") {
            quarantaine = try Pypi.recuperer(paquet: String(cible.dropFirst(5)), racine: racine, annulation: annulation).0
        } else if cible.contains("://") {
            quarantaine = try Quarantaine.cloner(lien: cible, racine: racine, annulation: annulation)
        } else {
            quarantaine = try Quarantaine.ouvrir(local: local, gatekeeper: gatekeeper, racine: racine, annulation: annulation)
        }
        do {
            // Archives, paquets et images rangés dans la cible : ouverts à côté, sans rien lancer.
            try quarantaine.ouvrirImbriques(racine: racine, gatekeeper: gatekeeper, annulation: annulation)
        } catch {
            if !garder { Plateforme.supprimer(quarantaine.dossier) }
            throw error
        }
        return quarantaine
    }

    public static func rapport(_ quarantaine: Quarantaine, inventaire: Inventaire? = nil, date: Date = .now,
                               annulation: Annulation? = nil) -> Rapport {
        let inventaire = inventaire ?? Inventaire(quarantaine: quarantaine)
        let textes = inventaire.textes.map(Texte.init)
        var constats = inventaire.constats
        // Un fichier par cœur : les règles ne partagent rien, et un gros dépôt passe de 45 s à quelques secondes.
        let parFichier = Parallele(textes.count)
        DispatchQueue.concurrentPerform(iterations: textes.count) { i in
            guard annulation?.demandee != true else { return }
            let texte = textes[i]
            parFichier.ranger(i, Moteur.appliquer(Regle.toutes, a: texte) + Analyses.blocsEncodes(texte) + Analyses.lignesGeantes(texte)
                + Secrets.constats(texte.fichier))
        }
        constats += parFichier.tout
        constats += Installation.analyser(inventaire.fichiers)
        for (chemin, etat) in quarantaine.origines where etat.executable {
            // Un fichier anodin marqué exécutable dans git : rare et sans raison honnête.
            if Inventaire.suffixesAnodins.contains((chemin as NSString).pathExtension.lowercased()) {
                constats.append(Constat(id: "", gravite: .faible, statut: .suspect, categorie: .autre, titre: "Fichier anodin marqué exécutable",
                                        fichier: chemin, lignes: [], extrait: "", explication: "Ce type de fichier n'a pas à être exécutable.",
                                        origine: .regle, regle: "inventaire.droits"))
            }
        }

        var rapport = Rapport(
            cible: Cible(type: quarantaine.sorte ?? (quarantaine.empreinte == nil ? .depot : .fichier), source: quarantaine.source, commit: quarantaine.commit,
                         empreinte: quarantaine.empreinte ?? (quarantaine.sorte == .app ? inventaire.empreintes.first?.sha256 : nil)),
            date: date, verdict: .rienDeGrave, resume: "", constats: constats, reseau: Analyses.hotes(textes),
            nonAnalyse: inventaire.nonAnalyse, couches: Couches(regles: true, ia: false), fichiersAnalyses: textes.count)
        rapport.constats = rapport.constatsTries.enumerated().map { i, constat in
            var c = constat
            c.id = "C\(i + 1)"
            return c
        }
        rapport.couches.yara = inventaire.yara
        rapport.verdict = Rapport.verdict(constats: rapport.constats, fichiersAnalyses: textes.count)
        rapport.resume = resume(rapport)
        if !inventaire.yara { rapport.resume += " Règles YARA non appliquées (yara n'est pas installé : \(Plateforme.installerYara))." }
        if inventaire.fichiers.contains(where: { $0.fiche && $0.chemin.hasSuffix("[imports]") }) {
            rapport.resume += " Les programmes compilés sont lus par leurs fonctions importées et leurs textes ; leur code machine n'est désassemblé qu'autour des appels sensibles."
        }
        return rapport
    }

    /// Renumérote les constats (triés) et recalcule le verdict, après un ajout.
    static let notes = [" Les programmes compilés", " Règles YARA", " Vulnérabilités connues"]

    /// Notes ajoutées après le résumé (programmes, YARA, OSV) : gardées telles quelles quand le résumé est réécrit.
    static func suiteDesNotes(_ resume: String) -> String {
        notes.compactMap { resume.range(of: $0)?.lowerBound }.min().map { String(resume[$0...]) } ?? ""
    }

    static func reclasser(_ r: Rapport) -> Rapport {
        var rapport = r
        rapport.constats = rapport.constatsTries.enumerated().map { i, constat in
            var c = constat
            c.id = "C\(i + 1)"
            return c
        }
        rapport.verdict = Rapport.verdict(constats: rapport.constats, fichiersAnalyses: rapport.fichiersAnalyses)
        rapport.resume = resume(rapport) + suiteDesNotes(r.resume)
        return rapport
    }

    static func resume(_ r: Rapport) -> String {
        let parGravite = Gravite.allCases.compactMap { g -> String? in
            let n = r.constats.filter { $0.gravite == g }.count
            return n == 0 ? nil : "\(n) \(g.titre.lowercased())"
        }
        let confirmes = r.constats.filter { $0.statut == .confirme && $0.gravite <= .elevee }.count
        var t = r.constats.isEmpty ? "Les règles automatiques n'ont rien relevé dans \(r.fichiersAnalyses) fichiers."
            : "\(r.constats.count) constats dans \(r.fichiersAnalyses) fichiers (\(parGravite.joined(separator: ", ")))"
                + (confirmes > 0 ? ", dont \(confirmes) grave\(confirmes > 1 ? "s" : "") confirmé\(confirmes > 1 ? "s" : "")." : ".")
        if !r.nonAnalyse.isEmpty { t += " \(r.nonAnalyse.count) fichier\(r.nonAnalyse.count > 1 ? "s" : "") non analysé\(r.nonAnalyse.count > 1 ? "s" : "")." }
        t += " Règles automatiques seules : un constat « suspect » est un indice à vérifier, pas une preuve."
        return t
    }

    /// Écrit `rapport.json` et `rapport.md` dans un dossier.
    public static func ecrire(_ rapport: Rapport, dans dossier: URL) throws {
        try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        try rapport.json().write(to: dossier.appending(path: "rapport.json"), options: .atomic)
        try Data(rapport.markdown().utf8).write(to: dossier.appending(path: "rapport.md"), options: .atomic)
    }
}

/// Résultats rangés par fichier depuis plusieurs fils, rendus dans l'ordre des fichiers.
private final class Parallele: @unchecked Sendable {
    private var cases: [[Constat]]
    private let verrou = NSLock()

    init(_ nombre: Int) { cases = Array(repeating: [], count: nombre) }

    func ranger(_ i: Int, _ constats: [Constat]) {
        verrou.lock()
        cases[i] = constats
        verrou.unlock()
    }

    var tout: [Constat] { cases.flatMap { $0 } }
}

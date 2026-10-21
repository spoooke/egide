import CerbereKit
import EgideUI
import SwiftUI

/// Rapport d'un audit : verdict en tête, résumé, constats par gravité (confirmés avant suspects), écartés par
/// l'IA à part, domaines cités, non analysé, bilan de la lecture par IA. Export et comparaison.
struct VueRapport: View {
    let audit: AuditGarde
    let modele: Modele
    /// Sections repliées (les moins urgentes le sont au départ).
    @State private var repliees: Set<String> = ["info", "ecartes", "non-analyse"]
    @State private var message: String?
    @State private var confirmer = false
    /// Constats à vérifier en attente de l'accord (élément du Mac).
    @State private var aVerifier: [String] = []

    private var rapport: Rapport { audit.rapport }

    var body: some View {
        let tries = rapport.constatsTries
        let ecartes = tries.filter(\.ecarte)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                entete
                explication
                trancher
                ForEach(Gravite.allCases, id: \.self) { gravite in
                    let lot = tries.filter { $0.gravite == gravite && !$0.ecarte }
                    if !lot.isEmpty {
                        TitreRepliable(titre: "\(gravite.titre) (\(lot.count))", ouvert: ouvert(gravite.rawValue))
                        if !repliees.contains(gravite.rawValue) { ForEach(lot, id: \.id) { carte($0) } }
                    }
                }
                if tries.isEmpty { Text("Aucun constat.").frame(maxWidth: .infinity, alignment: .leading).egideCard() }
                if !ecartes.isEmpty {
                    TitreRepliable(titre: "Écartés par la lecture par IA (\(ecartes.count))", ouvert: ouvert("ecartes"))
                    if !repliees.contains("ecartes") {
                        Text("Indices des règles automatiques que la lecture du code a jugés sans danger. Ils ne pèsent pas sur le verdict.")
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach(ecartes, id: \.id) { CarteConstat(constat: $0) }
                    }
                }
                let hotes = rapport.reseau.adresses + rapport.reseau.domaines
                if !hotes.isEmpty {
                    TitreRepliable(titre: "Domaines et adresses cités dans le code (\(hotes.count))", ouvert: ouvert("domaines"))
                    if !repliees.contains("domaines") {
                        VStack(spacing: 6) { ForEach(hotes, id: \.nom) { LigneHote(hote: $0) } }.egideCard()
                    }
                }
                if !rapport.nonAnalyse.isEmpty {
                    TitreRepliable(titre: "Non analysé (\(rapport.nonAnalyse.count))", ouvert: ouvert("non-analyse"))
                    if !repliees.contains("non-analyse") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(rapport.nonAnalyse.prefix(300).enumerated()), id: \.offset) { _, n in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(verbatim: n.fichier.montrable).font(.callout.monospaced())
                                    Spacer(minLength: 8)
                                    Text(verbatim: n.raison.montrable).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if rapport.nonAnalyse.count > 300 { Text("… et \(rapport.nonAnalyse.count - 300) autres").foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .egideCard()
                    }
                }
                if let ia = rapport.ia { bilan(ia) }
            }
            .padding(24)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        // Accord avant de vérifier un élément du Mac : domaine et contenu nommés, pour cette fois seulement.
        .alert("Envoyer ces passages à anthropic.com ?", isPresented: Binding { !aVerifier.isEmpty } set: { if !$0 { aVerifier = [] } }) {
            Button("Envoyer") { modele.verifier(aVerifier, de: audit); aVerifier = [] }
            Button("Annuler", role: .cancel) { aVerifier = [] }
        } message: {
            Text("Pour cette vérification seulement (\(aVerifier.joined(separator: ", "))), Cerbère relit la cible en quarantaine et l'IA reçoit \(Verifications.cequiPart).")
        }
    }

    private func ouvert(_ cle: String) -> Binding<Bool> {
        Binding { !repliees.contains(cle) } set: { if $0 { repliees.remove(cle) } else { repliees.insert(cle) } }
    }

    private var entete: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: rapport.verdict.symbole).font(.largeTitle)
                Text(rapport.verdict.titre).font(.system(.largeTitle, design: .rounded, weight: .bold))
            }
            .foregroundStyle(rapport.verdict.couleur)
            Text(verbatim: rapport.cible.source.montrable).font(.callout.monospaced())
            Text(verbatim: precisions).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: rapport.resume.montrable).fixedSize(horizontal: false, vertical: true)
            Text("Un audit statique baisse le risque, il ne prouve pas qu'un logiciel est sain.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Menu("Exporter") {
                    Button("Markdown (rapport.md)…") { exporter(.markdown) }
                    Button("JSON (rapport.json)…") { exporter(.json) }
                    Button("PDF…") { exporter(.pdf) }
                }
                Menu("Comparer avec") {
                    // La même cible d'abord (deux versions d'un dépôt) ; les autres audits restent proposés,
                    // pour un dossier copié ailleurs ou un dépôt et son paquet.
                    let memes = modele.autresAudits(de: audit), autres = modele.audits.filter { $0.id != audit.id && !memes.contains($0) }
                    Section("Même cible") {
                        if memes.isEmpty { Text("Aucun autre audit de cette cible") }
                        ForEach(memes) { choix($0, nom: false) }
                    }
                    if !autres.isEmpty { Section("Autres audits") { ForEach(autres) { choix($0, nom: true) } } }
                }
                Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([audit.dossier]) }
                if let message { Text(verbatim: message).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .egideCard()
    }

    /// « Expliqué simplement » : déjà rédigé (dépliable), ou à demander. Pour un élément du Mac, rien ne part
    /// sans un oui donné ici, domaine et contenu nommés.
    @ViewBuilder
    private var explication: some View {
        if let n = rapport.neophyte {
            TitreRepliable(titre: "Expliqué simplement", ouvert: ouvert("neophyte"))
            if !repliees.contains("neophyte") { CarteExplication(explication: n) }
        } else {
            let enCours = modele.explications.contains(audit.id)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pas tout compris ?").font(.headline)
                        Text("L'IA peut redire ce rapport en mots simples, sans jargon : ce que ça veut dire pour toi et quoi faire.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if enCours {
                        ProgressView().controlSize(.small)
                        Text("Environ 30 s…").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Button("Expliquer simplement") {
                            if Confidentialite.accordRequis(cible: rapport.cible.source) { confirmer = true } else { modele.expliquer(audit) }
                        }
                    }
                }
                if let erreur = modele.erreursExplication[audit.id] {
                    Text(verbatim: erreur.montrable).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .egideCard()
            .alert("Envoyer le rapport à anthropic.com ?", isPresented: $confirmer) {
                Button("Envoyer") { modele.expliquer(audit) }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Pour cette explication seulement, l'IA reçoit \(Neophyte.cequiPart).")
            }
        }
    }

    private func carte(_ c: Constat) -> some View {
        let cle = modele.cle(audit, c.id)
        return CarteConstat(constat: c, verifier: Verifications.verifiable(c) ? { demanderVerification([c.id]) } : nil,
                            enVerification: modele.verifications.contains(cle), echec: modele.erreursVerification[cle])
    }

    /// Pour un élément du Mac, rien ne part sans un oui donné ici ; un lien public est récupéré de nouveau sans demander.
    private func demanderVerification(_ ids: [String]) {
        if Confidentialite.accordRequis(cible: rapport.cible.source) {
            aVerifier = ids
        } else {
            modele.verifier(ids, de: audit)
        }
    }

    /// Les élevés et critiques encore « suspects » : un bouton pour les trancher tous.
    @ViewBuilder
    private var trancher: some View {
        let restants = Verifications.aTrancher(rapport)
        let enCours = restants.contains { modele.verifications.contains(modele.cle(audit, $0.id)) }
        if !restants.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "stethoscope").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(restants.count) constat\(restants.count > 1 ? "s" : "") élevé\(restants.count > 1 ? "s" : "") ou critique\(restants.count > 1 ? "s" : "") à trancher").font(.headline)
                    Text("Faux positif ou vraiment grave ? L'IA relit chaque passage avec son contexte\(Confidentialite.accordRequis(cible: rapport.cible.source) ? "" : " (la cible est récupérée de nouveau)"). Environ 1 min.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if enCours { ProgressView().controlSize(.small) } else {
                    Button("Vérifier les élevés") { demanderVerification(restants.map(\.id)) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .egideCard()
        }
    }

    private func choix(_ autre: AuditGarde, nom: Bool) -> some View {
        let r = autre.rapport
        return Button { modele.comparer(audit, autre) } label: {
            Text(verbatim: "\(nom ? r.nomCourt.montrable + " · " : "")\(r.date.formatted(date: .numeric, time: .shortened)) · \(r.verdict.titre)\(r.cible.commit.map { " · \($0.prefix(7))" } ?? "")")
        }
    }

    private var precisions: String {
        var morceaux = [rapport.date.formatted(date: .long, time: .shortened)]
        if let commit = rapport.cible.commit { morceaux.append("commit \(commit.prefix(12))") }
        if let empreinte = rapport.cible.empreinte { morceaux.append("SHA-256 \(empreinte.prefix(16))…") }
        morceaux.append("\(rapport.fichiersAnalyses) fichiers analysés")
        morceaux.append(rapport.couches.ia ? "règles automatiques + lecture par IA" : "règles automatiques seules")
        if rapport.couches.gatekeeper == true { morceaux.append("Gatekeeper interrogé") }
        if rapport.couches.reputation == true { morceaux.append("empreinte comparée sur VirusTotal") }
        if rapport.couches.yara == true { morceaux.append("règles YARA") }
        if rapport.couches.vulnerabilites == true { morceaux.append("dépendances comparées à la base OSV") }
        return morceaux.joined(separator: " · ").montrable
    }

    private func bilan(_ ia: BilanIA) -> some View {
        VStack(spacing: 6) {
            EgideSectionTitle("Bilan de la lecture par IA")
            Chiffre("Modèle", ia.modele.montrable)
            Chiffre("Fichiers lus en entier", "\(ia.fichiersLus) sur \(ia.fichiersLisibles) lisibles")
            Chiffre("Fichiers lus en partie (passages sensibles)", "\(ia.fichiersEnPartie)")
            Chiffre("Lots lus", "\(ia.lots - ia.lotsEchoues) sur \(ia.lots)")
            Chiffre("Constats de l'IA rejetés (citation introuvable)", "\(ia.citationsIntrouvables)")
            Chiffre("Retirés ou baissés à la relecture", "\(ia.retiresALaRelecture)")
            Chiffre("Secrets masqués avant l'envoi", "\(ia.secretsMasques)")
            Chiffre("Tentative de manipulation relevée", ia.manipulation ? "oui : l'IA n'a rien pu écarter dans les fichiers lus avec elle" : "non")
        }
        .egideCard()
        .padding(.top, 6)
    }

    private func exporter(_ format: Export.Format) {
        let panneau = NSSavePanel()
        let nom = rapport.nomCourt.montrable.map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? $0 : "-" }
        panneau.nameFieldStringValue = "cerbere-\(String(nom)).\(format.suffixe)"
        guard panneau.runModal() == .OK, let url = panneau.url else { return }
        do {
            try Export.ecrire(rapport, format, vers: url)
            message = "Exporté : \(url.lastPathComponent)"
        } catch {
            message = "Export impossible : \(error.localizedDescription)"
        }
    }
}

private struct Chiffre: View {
    let titre: String, valeur: String

    init(_ titre: String, _ valeur: String) {
        self.titre = titre
        self.valeur = valeur
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: titre)
            Spacer(minLength: 12)
            Text(verbatim: valeur).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

/// Ce qui a changé entre deux audits de la même cible.
struct VueComparaison: View {
    let ancien: AuditGarde
    let nouveau: AuditGarde
    let fermer: () -> Void

    var body: some View {
        let c = Comparaison(ancien: ancien.rapport, nouveau: nouveau.rapport)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Button("‹ Retour au rapport", action: fermer).buttonStyle(.link)
                    Text("Comparaison").font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text(verbatim: nouveau.rapport.cible.source.montrable).font(.callout.monospaced())
                    HStack(alignment: .top, spacing: 14) {
                        version("Avant", ancien.rapport)
                        Image(systemName: "arrow.right").font(.title2).foregroundStyle(.secondary).padding(.top, 18)
                        version("Après", nouveau.rapport)
                    }
                    Text(c.verdictChange ? "Le verdict a changé." : "Le verdict n'a pas changé.").fontWeight(c.verdictChange ? .bold : .regular)
                    Text("\(c.apparus.count) constat\(c.apparus.count > 1 ? "s" : "") apparu\(c.apparus.count > 1 ? "s" : ""), \(c.disparus.count) disparu\(c.disparus.count > 1 ? "s" : ""), \(c.inchanges) inchangé\(c.inchanges > 1 ? "s" : "") · \(c.nouveauxDomaines.count) nouveau\(c.nouveauxDomaines.count > 1 ? "x" : "") domaine\(c.nouveauxDomaines.count > 1 ? "s" : "")")
                        .font(.callout).foregroundStyle(.secondary)
                    if c.rienNeChange { Text("Rien n'a changé entre ces deux audits.") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .egideCard()
                if !c.apparus.isEmpty {
                    EgideSectionTitle("Constats apparus (\(c.apparus.count))").padding(.top, 6)
                    ForEach(c.apparus, id: \.id) { CarteConstat(constat: $0) }
                }
                if !c.nouveauxDomaines.isEmpty {
                    EgideSectionTitle("Nouveaux domaines et adresses (\(c.nouveauxDomaines.count))").padding(.top, 6)
                    VStack(spacing: 6) { ForEach(c.nouveauxDomaines, id: \.nom) { LigneHote(hote: $0) } }.egideCard()
                }
                if !c.disparus.isEmpty {
                    EgideSectionTitle("Constats disparus (\(c.disparus.count))").padding(.top, 6)
                    ForEach(c.disparus, id: \.id) { CarteConstat(constat: $0).opacity(0.7) }
                }
                if !c.domainesDisparus.isEmpty {
                    EgideSectionTitle("Domaines et adresses disparus (\(c.domainesDisparus.count))").padding(.top, 6)
                    VStack(spacing: 6) { ForEach(c.domainesDisparus, id: \.nom) { LigneHote(hote: $0) } }.egideCard().opacity(0.7)
                }
            }
            .padding(24)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
    }

    private func version(_ titre: String, _ r: Rapport) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(titre.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Label(r.verdict.titre, systemImage: r.verdict.symbole).font(.headline).foregroundStyle(r.verdict.couleur)
            Text(verbatim: r.date.formatted(date: .numeric, time: .shortened) + (r.cible.commit.map { " · commit \($0.prefix(7))" } ?? "").montrable)
                .font(.caption).foregroundStyle(.secondary)
            Text(verbatim: "\(r.constats.filter { !$0.ecarte }.count) constats · \(r.couches.ia ? "règles + IA" : "règles seules")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

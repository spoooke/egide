import EgideUI
import SwiftUI

/// Rapport d'un audit fait sur le Mac, relu sur le serveur Argos. Même ordre que dans l'app Mac : verdict, résumé,
/// explication simple (repliée, préparée par le relais du Mac), constats par gravité, écartés par l'IA, domaines cités, non analysé, bilan de la lecture par IA.
/// Tout ce qui vient du code audité ou de l'IA est du texte brut (`Text(verbatim:)` après `montrable`) :
/// ni Markdown, ni lien, rien de cliquable.
struct VueRapportDistant: View {
    /// Identifiant de l'audit sur le serveur.
    let id: String
    @State private var rapport: Rapport?
    @State private var erreur: String?
    /// Sections repliées (les moins urgentes le sont au départ).
    @State private var repliees: Set<String> = ["neophyte", "info", "ecartes", "domaines", "non-analyse"]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let rapport {
                    contenu(rapport)
                } else if let erreur {
                    ContentUnavailableView("Rapport illisible", systemImage: "doc.questionmark", description: Text(verbatim: erreur))
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .egideScreen()
        .foregroundStyle(EgideTheme.encre)
        .navigationTitle("Rapport")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard rapport == nil else { return }
            do {
                guard let lu = try await CerbereKit.audit(id) else {
                    erreur = "Argos n'est pas connecté."
                    return
                }
                if let recu = lu.rapport { rapport = recu } else { erreur = "Le serveur n'a plus ce rapport. Il reste sur le Mac, dans l'app Cerbère." }
            } catch is CancellationError {
            } catch {
                erreur = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func contenu(_ rapport: Rapport) -> some View {
        let tries = rapport.constatsTries
        let ecartes = tries.filter(\.ecarte)
        entete(rapport)
        if let n = rapport.neophyte {
            TitreRepliable(titre: "Expliqué simplement", ouvert: ouvert("neophyte"))
            if !repliees.contains("neophyte") { CarteExplication(explication: n) }
        }
        ForEach(Gravite.allCases, id: \.self) { gravite in
            let lot = tries.filter { $0.gravite == gravite && !$0.ecarte }
            if !lot.isEmpty {
                TitreRepliable(titre: "\(gravite.titre) (\(lot.count))", ouvert: ouvert(gravite.rawValue))
                if !repliees.contains(gravite.rawValue) { ForEach(lot, id: \.id) { CarteConstat(constat: $0) } }
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
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(hotes, id: \.nom) { hote in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: hote.nom.montrable).font(.callout.monospaced()).textSelection(.enabled)
                            Text(verbatim: "\(hote.occurrences) fois · \(hote.fichiers.map(\.montrable).joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .egideCard()
            }
        }
        if !rapport.nonAnalyse.isEmpty {
            TitreRepliable(titre: "Non analysé (\(rapport.nonAnalyse.count))", ouvert: ouvert("non-analyse"))
            if !repliees.contains("non-analyse") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(rapport.nonAnalyse.prefix(100).enumerated()), id: \.offset) { _, n in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: n.fichier.montrable).font(.callout.monospaced()).lineLimit(2).truncationMode(.middle)
                            Text(verbatim: n.raison.montrable).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if rapport.nonAnalyse.count > 100 { Text("… et \(rapport.nonAnalyse.count - 100) autres").foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .egideCard()
            }
        }
        if let ia = rapport.ia { bilan(ia) }
    }

    private func ouvert(_ cle: String) -> Binding<Bool> {
        Binding { !repliees.contains(cle) } set: { if $0 { repliees.remove(cle) } else { repliees.insert(cle) } }
    }

    private func entete(_ rapport: Rapport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: rapport.verdict.symbole).font(.title)
                Text(rapport.verdict.titre).font(.system(.title, design: .rounded, weight: .bold))
            }
            .foregroundStyle(rapport.verdict.couleur)
            Text(verbatim: rapport.cible.source.montrable).font(.callout.monospaced()).textSelection(.enabled)
            Text(verbatim: precisions(rapport)).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: rapport.resume.montrable).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Text("Un audit statique baisse le risque, il ne prouve pas qu'un logiciel est sain.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .egideCard()
    }

    private func precisions(_ rapport: Rapport) -> String {
        var morceaux = [rapport.date.formatted(Date.FormatStyle(date: .long, time: .shortened, locale: Locale(identifier: "fr_FR")))]
        if let commit = rapport.cible.commit { morceaux.append("commit \(commit.prefix(12))") }
        morceaux.append("\(rapport.fichiersAnalyses) fichiers analysés")
        morceaux.append(rapport.couches.ia ? "règles automatiques + lecture par IA" : "règles automatiques seules")
        return morceaux.joined(separator: " · ").montrable
    }

    private func bilan(_ ia: BilanIA) -> some View {
        VStack(spacing: 6) {
            EgideSectionTitle("Bilan de la lecture par IA")
            Chiffre("Modèle", ia.modele.montrable)
            Chiffre("Fichiers lus en entier", "\(ia.fichiersLus) sur \(ia.fichiersLisibles)")
            Chiffre("Fichiers lus en partie", "\(ia.fichiersEnPartie)")
            Chiffre("Lots lus", "\(ia.lots - ia.lotsEchoues) sur \(ia.lots)")
            Chiffre("Constats de l'IA rejetés", "\(ia.citationsIntrouvables)")
            Chiffre("Retirés ou baissés à la relecture", "\(ia.retiresALaRelecture)")
            Chiffre("Secrets masqués avant l'envoi", "\(ia.secretsMasques)")
            Chiffre("Tentative de manipulation", ia.manipulation ? "oui : l'IA n'a rien pu écarter" : "non")
        }
        .egideCard()
        .padding(.top, 6)
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

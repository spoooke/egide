import EgideUI
import SwiftUI

extension Verdict {
    public var couleur: Color {
        switch self {
        case .nePasInstaller: .red
        case .risque: .orange
        case .rienDeGrave: .green
        case .incomplet: .gray
        }
    }

    public var symbole: String {
        switch self {
        case .nePasInstaller: "xmark.octagon.fill"
        case .risque: "exclamationmark.triangle.fill"
        case .rienDeGrave: "checkmark.shield.fill"
        case .incomplet: "questionmark.circle.fill"
        }
    }
}

extension Gravite {
    public var couleur: Color {
        switch self {
        case .critique: .red
        case .elevee: .orange
        case .moyenne: .yellow
        case .faible: EgideTheme.bleu
        case .info: .gray
        }
    }
}

extension Constat {
    /// « fichier:12 » ou « fichier:12-18 ».
    public var lieu: String {
        lignes.isEmpty ? fichier : lignes.first == lignes.last ? "\(fichier):\(lignes[0])" : "\(fichier):\(lignes[0])-\(lignes.last!)"
    }
}

/// Petite étiquette colorée (gravité, statut).
public struct Pastille: View {
    let texte: String
    let couleur: Color
    var pleine = false

    public init(texte: String, couleur: Color, pleine: Bool = false) {
        self.texte = texte
        self.couleur = couleur
        self.pleine = pleine
    }

    public var body: some View {
        Text(texte)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(pleine ? Color.white : couleur)
            .background(pleine ? couleur : couleur.opacity(0.14), in: .capsule)
    }
}

/// Un constat : titre, endroit, explication, puis l'extrait en texte brut à chasse fixe. Tout ce qui vient du
/// code audité passe par `Text(verbatim:)` : ni Markdown, ni lien cliquable, ni rendu d'aucune sorte.
public struct CarteConstat: View {
    let constat: Constat
    /// « Vérifier ce point » (app Mac) : absent sur l'iPhone ou pour un constat qui ne se vérifie pas.
    let verifier: (() -> Void)?
    let enVerification: Bool
    let echec: String?

    public init(constat: Constat, verifier: (() -> Void)? = nil, enVerification: Bool = false, echec: String? = nil) {
        self.constat = constat
        self.verifier = verifier
        self.enVerification = enVerification
        self.echec = echec
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Sur l'iPhone, les étiquettes passent sous le titre : la largeur manque.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    titre.fixedSize()
                    Spacer(minLength: 8)
                    etiquettes
                }
                VStack(alignment: .leading, spacing: 6) {
                    titre
                    etiquettes
                }
            }
            Text(verbatim: constat.lieu.montrable)
                .font(.callout.monospaced())
                
            Text(verbatim: "\(constat.categorie.titre) · \(constat.origine == .ia ? "lecture par IA" : "règle automatique")")
                .font(.caption).foregroundStyle(.secondary)
            Text(verbatim: constat.explication.montrable).fixedSize(horizontal: false, vertical: true)
            if let note = constat.noteIA, !note.isEmpty {
                Text(verbatim: "Lecture par IA : \(note.montrable)").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !constat.extrait.isEmpty { Extrait(texte: constat.extrait) }
            if let v = constat.verification { BlocVerification(verification: v) }
            if enVerification {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Vérification en cours…").font(.callout).foregroundStyle(.secondary)
                }
            } else if let verifier {
                HStack(spacing: 10) {
                    Button(constat.verification == nil ? "Vérifier ce point" : "Vérifier à nouveau", systemImage: "stethoscope", action: verifier)
                    if constat.verification == nil {
                        Text(constat.statut == .confirme ? "L'IA relit ce passage avec son contexte et dit si c'est normal pour ce type de logiciel ou si c'est grave."
                             : "L'IA relit ce passage avec son contexte et dit si c'est un faux positif ou si c'est grave.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let echec {
                Text(verbatim: "Vérification impossible : \(echec.montrable)").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .egideCard()
    }
}

extension Verification.Conclusion {
    public var couleur: Color {
        switch self {
        case .fauxPositif, .normal: .green
        case .aSurveiller: .orange
        case .grave: .red
        }
    }

    public var symbole: String {
        switch self {
        case .fauxPositif: "checkmark.circle.fill"
        case .normal: "checkmark.seal.fill"
        case .aSurveiller: "eye.fill"
        case .grave: "exclamationmark.octagon.fill"
        }
    }
}

/// Résultat d'une vérification ciblée : conclusion en couleur, explication simple, ce que Cerbère en a fait.
public struct BlocVerification: View {
    let verification: Verification

    public init(verification: Verification) { self.verification = verification }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Vérification : \(verification.conclusion.titre)", systemImage: verification.conclusion.symbole)
                .font(.callout.weight(.semibold)).foregroundStyle(verification.conclusion.couleur)
            Text(verbatim: verification.explication.montrable).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "Effet : \(verification.effet.montrable) · \(verification.date.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(verification.conclusion.couleur.opacity(0.08), in: .rect(cornerRadius: 8, style: .continuous))
    }
}

extension CarteConstat {
    private var titre: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: constat.id).font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(verbatim: constat.titre.montrable).font(.headline)
        }
    }

    private var etiquettes: some View {
        HStack(spacing: 8) {
            Pastille(texte: constat.gravite.titre, couleur: constat.gravite.couleur)
            // « Vu dans le code » : rouge plein seulement quand c'est élevé ou critique ; sinon neutre, pour ne pas inquiéter à tort.
            Pastille(texte: constat.statut == .confirme ? "Vu dans le code" : "Suspect",
                     couleur: constat.statut == .confirme && constat.gravite <= .elevee ? .red : .gray,
                     pleine: constat.statut == .confirme && constat.gravite <= .elevee)
            if let v = constat.verification { Pastille(texte: v.conclusion.titre, couleur: v.conclusion.couleur) }
        }
    }
}

/// Extrait du code audité : bloc à chasse fixe, jamais interprété.
/// Pas de `.textSelection` dans les rapports : sur macOS 27, un texte sélectionnable coupé par le bord d'une zone qui
/// défile fait boucler l'accessibilité jusqu'au plantage dès qu'un outil lit l'écran (trouvé le 2026-10-14).
/// Pour copier, il y a l'export.
public struct Extrait: View {
    let texte: String

    public init(texte: String) { self.texte = texte }

    public var body: some View {
        Text(verbatim: texte.montrable)
            .font(.system(.callout, design: .monospaced))
            
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(EgideTheme.bleu.opacity(0.07), in: .rect(cornerRadius: 8, style: .continuous))
            .accessibilityLabel("Extrait du code audité")
    }
}

/// Titre de section qu'on peut replier.
public struct TitreRepliable: View {
    let titre: String
    @Binding var ouvert: Bool

    public init(titre: String, ouvert: Binding<Bool>) {
        self.titre = titre
        _ouvert = ouvert
    }

    public var body: some View {
        Button { ouvert.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").rotationEffect(.degrees(ouvert ? 90 : 0)).font(.caption.weight(.bold))
                EgideSectionTitle(titre)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(EgideTheme.bleu)
        .padding(.top, 6)
    }
}

/// Ligne « nom du domaine — nombre de fois, fichiers ».
public struct LigneHote: View {
    let hote: Reseau.Hote

    public init(hote: Reseau.Hote) { self.hote = hote }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: hote.nom.montrable).font(.callout.monospaced())
            Spacer(minLength: 8)
            Text(verbatim: "\(hote.occurrences) fois · \(hote.fichiers.map(\.montrable).joined(separator: ", "))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// « Expliqué simplement » : le rapport redit en mots de tous les jours par l'IA. Texte brut, comme le reste.
public struct CarteExplication: View {
    let explication: Explication

    public init(explication: Explication) { self.explication = explication }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: explication.enBref.montrable).fixedSize(horizontal: false, vertical: true)
            liste("À savoir", explication.aSavoir, symbole: "info.circle")
            liste("Que faire", explication.queFaire, symbole: "hand.point.right")
            Text(verbatim: "Rédigé par l'IA (\(explication.modele.montrable)) à partir du rapport seul. Le verdict ci-dessus reste celui de Cerbère.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .egideCard()
    }

    @ViewBuilder
    private func liste(_ titre: String, _ lignes: [String], symbole: String) -> some View {
        if !lignes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(titre).font(.headline)
                ForEach(Array(lignes.enumerated()), id: \.offset) { _, ligne in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: symbole).foregroundStyle(EgideTheme.bleu).font(.callout)
                        Text(verbatim: ligne.montrable).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

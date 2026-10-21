import CerbereKit
import EgideUI
import SwiftUI

/// Accueil : coller un lien ou glisser un dossier, voir ce qui sera contacté, régler la lecture par IA, lancer.
struct VueNouvelAudit: View {
    @Bindable var modele: Modele
    @State private var survol = false
    @State private var cle = ""
    @State private var cleRefusee = false

    private var saisie: Saisie { Saisie(modele.texte) }

    var body: some View {
        PageAEnTete(EgideHeader("Cerbère", sousTitre: "Audit de sécurité avant d'installer", image: Image(nsImage: NSApp.applicationIconImage))) {
            VStack(spacing: 14) {
                cible
                if saisie != .vide { avant }
                if saisie.enLignePossible { enLigne }
                reglages
                if let erreur = modele.erreur {
                    Text(verbatim: erreur.montrable).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).egideCard()
                }
                Button("Lancer l'audit") { modele.lancer() }
                    .buttonStyle(.egide)
                    .disabled(saisie.cible == nil)
                    .opacity(saisie.cible == nil ? 0.5 : 1)
                    .keyboardShortcut(.defaultAction)
                Text("Rien n'est exécuté, ouvert ni installé : la cible est copiée en lecture seule dans une quarantaine, lue comme une donnée, puis supprimée. Un audit statique baisse le risque, il ne prouve pas qu'un logiciel est sain.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private var cible: some View {
        VStack(alignment: .leading, spacing: 10) {
            EgideSectionTitle("Quoi auditer")
            HStack {
                TextField("Lien https://…, pypi:nom, ou chemin d'un élément du Mac", text: $modele.texte)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if saisie.cible != nil { modele.lancer() } }
                Button("Coller") { if let t = NSPasteboard.general.string(forType: .string) { modele.texte = String(t.prefix(2000)) } }
                Button("Choisir…", action: choisir)
            }
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down").font(.title3)
                Text("ou glisse ici une app, une image disque, un paquet, un fichier, un dossier ou une archive")
            }
            .foregroundStyle(survol ? EgideTheme.bleu : .secondary)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(survol ? EgideTheme.bleu : EgideTheme.bleu.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        }
        .egideCard()
        // Toute la carte accepte le dépôt : seul le chemin est retenu, rien n'est ouvert.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL else { return false }
            modele.texte = url.path
            return true
        } isTargeted: { survol = $0 }
    }

    /// Ce qui sera contacté, affiché avant toute récupération.
    private var avant: some View {
        VStack(alignment: .leading, spacing: 8) {
            EgideSectionTitle("Avant de lancer")
            switch saisie {
            case .lien(_, let hote):
                Ligne("network", "Récupération depuis", hote, "Clone de quarantaine, sans identifiants : aucun script du dépôt n'est lancé.")
                ia(publique: true)
                osv
            case .paquet(let nom):
                Ligne("network", "Téléchargement depuis", "pypi.org et files.pythonhosted.org",
                      "Archives du paquet « \(nom) », empreinte vérifiée, ouvertes sans rien installer.")
                ia(publique: true)
                osv
            case .local(_, let nature):
                Ligne("internaldrive", nature.titre, nil, nature.detail)
                ia(publique: false)
                Toggle(isOn: $modele.vulnerabilites) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("Chercher les failles connues des dépendances sur")
                            Text(verbatim: Vulnerabilites.domaine).fontWeight(.bold)
                        }
                        Text("Pour cet audit seulement. Seuls le nom et la version de chaque dépendance partent (ni code, ni chemin, ni nom du projet).")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .refusee(let raison):
                Label { Text(verbatim: raison.montrable) } icon: { Image(systemName: "xmark.octagon.fill") }.foregroundStyle(.red)
            case .vide: EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .egideCard()
    }

    private var osv: some View {
        Ligne("checklist", "Failles connues des dépendances : envoi à", Vulnerabilites.domaine,
              "Noms et versions des dépendances seulement, déjà publics. Un paquet malveillant connu donne « Ne pas installer ».")
    }

    @ViewBuilder private func ia(publique: Bool) -> some View {
        if modele.sansIA {
            Ligne("lock.shield", "Lecture par IA coupée", nil, publique ? "Le code ne part nulle part ailleurs." : "Rien ne sort du Mac.")
        } else if publique {
            Ligne("sparkles", "Lecture par IA : envoi à", "anthropic.com", "Code public, envoyé sans autre question (Claude Code verrouillé, sans outil ; secrets masqués).")
        } else {
            Ligne("hand.raised", "Lecture par IA : seulement après ton accord", nil,
                  "Après les règles, un aperçu de ce qui partirait à anthropic.com (fichiers, taille, secrets masqués) te sera montré. Sans « oui », rien ne part.")
        }
    }

    /// Vérifications qui sortent du Mac : décochées à chaque nouvel audit, le domaine est nommé.
    private var enLigne: some View {
        VStack(alignment: .leading, spacing: 10) {
            EgideSectionTitle("Vérifications en ligne (facultatif, pour cet audit seulement)")
            Toggle(isOn: $modele.gatekeeper) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Demander le verdict de Gatekeeper")
                    Text("C'est le contrôle que fait macOS à l'ouverture d'une app téléchargée (signature et notarisation). Pour répondre, macOS peut interroger Apple : seule une empreinte de la signature part.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(isOn: $modele.reputation) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Comparer l'empreinte sur")
                        Text(verbatim: Reputation.domaine).fontWeight(.bold)
                    }
                    Text("Seule l'empreinte SHA-256 du fichier est envoyée (ni le fichier, ni son nom) : VirusTotal dit combien d'antivirus le connaissent comme malveillant.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!modele.aUneCle)
            if modele.aUneCle {
                HStack {
                    Label("Clé VirusTotal rangée dans le trousseau", systemImage: "key.fill").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Oublier la clé") { modele.oublierCle() }.controlSize(.small)
                }
            } else {
                HStack {
                    SecureField("Clé VirusTotal (gratuite, à créer sur ton compte)", text: $cle).textFieldStyle(.roundedBorder)
                    Button("Ranger dans le trousseau") {
                        cleRefusee = !modele.enregistrerCle(cle)
                        cle = ""
                    }
                    .disabled(cle.isEmpty)
                }
                if cleRefusee { Text("Cette clé n'a pas la forme attendue : rien n'a été enregistré.").font(.caption).foregroundStyle(.red) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .egideCard()
    }

    private var reglages: some View {
        VStack(spacing: 10) {
            EgideSectionTitle("Lecture par IA")
            Toggle("Sans IA (règles automatiques seules, rien n'est envoyé)", isOn: $modele.sansIA)
                .frame(maxWidth: .infinity, alignment: .leading)
            Stepper(value: $modele.lots, in: 1...30) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Lots lus au plus : \(modele.lots)")
                    Text("borne le quota de l'abonnement (un lot ≈ 150 Ko de code)").foregroundStyle(.secondary).font(.caption)
                }
            }
            .disabled(modele.sansIA)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .egideCard()
    }

    private func choisir() {
        let panneau = NSOpenPanel()
        panneau.canChooseDirectories = true
        panneau.canChooseFiles = true
        panneau.allowsMultipleSelection = false
        panneau.prompt = "Auditer"
        if panneau.runModal() == .OK, let url = panneau.url { modele.texte = url.path }
    }
}

extension Quarantaine.Nature {
    var titre: String {
        switch self {
        case .dossier: "Dossier de ce Mac"
        case .app: "App de ce Mac"
        case .image: "Image disque de ce Mac"
        case .paquet: "Paquet d'installation de ce Mac"
        case .archive: "Archive de ce Mac"
        case .fichier: "Fichier de ce Mac"
        }
    }

    /// Ce qui sera fait pour l'obtenir, sans rien lancer.
    var detail: String {
        switch self {
        case .dossier, .fichier: "Rien n'est téléchargé : copie en lecture seule dans la quarantaine."
        case .archive: "Ouverte dans la quarantaine sans rien installer ; les archives qu'elle contient aussi."
        case .app: "Signature vérifiée sur place, puis copie en lecture seule. L'app n'est pas lancée."
        case .image: "Montée en lecture seule, cachée du Finder, sans ouverture automatique, copiée puis démontée."
        case .paquet: "Développé sans être installé : ses scripts sont lus, jamais lancés."
        }
    }
}

/// Ligne d'information : symbole, phrase, valeur mise en avant (un domaine), précision en dessous.
private struct Ligne: View {
    let symbole: String, titre: String, valeur: String?, detail: String

    init(_ symbole: String, _ titre: String, _ valeur: String?, _ detail: String) {
        self.symbole = symbole
        self.titre = titre
        self.valeur = valeur
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbole).foregroundStyle(EgideTheme.bleu).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: titre)
                    if let valeur { Text(verbatim: valeur.montrable).fontWeight(.bold) }
                }
                Text(verbatim: detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Audit en cours : étapes, lots lus, demande d'accord, arrêt.
struct VueAvancement: View {
    let enCours: EnCours
    let modele: Modele
    @Environment(\.openWindow) private var ouvrirFenetre

    var body: some View {
        PageAEnTete(EgideHeader("Audit en cours", sousTitre: nil, image: Image(nsImage: NSApp.applicationIconImage))) {
            VStack(spacing: 14) {
                Text(verbatim: enCours.nom.montrable).font(.callout.monospaced()).lineLimit(2).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 12) {
                    etape(.recuperation, "Récupération", detail: recuperation)
                    etape(.regles, "Règles automatiques", detail: "Sur le Mac, rien n'est envoyé.")
                    if enCours.avecIA {
                        etape(.lecture, "Lecture par IA", detail: enCours.total > 0 ? "\(enCours.fait) lot\(enCours.fait > 1 ? "s" : "") lu\(enCours.fait > 1 ? "s" : "") sur \(enCours.total)" : nil)
                        if enCours.etape == .lecture, enCours.total > 0 {
                            ProgressView(value: Double(enCours.fait), total: Double(enCours.total)).padding(.leading, 30)
                        }
                        etape(.relecture, "Relecture des constats", detail: nil)
                        etape(.resume, "Résumé", detail: nil)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .egideCard()
                if let apercu = enCours.demande { accord(apercu) }
                if !enCours.message.isEmpty, enCours.demande == nil {
                    Text(verbatim: enCours.message.montrable).font(.callout).foregroundStyle(.secondary)
                }
                Button(enCours.arretDemande ? "Arrêt en cours…" : "Annuler l'audit") { modele.annuler() }
                    .buttonStyle(.egideSecondary)
                    .disabled(enCours.arretDemande)
                    .keyboardShortcut(.cancelAction)
                Button("Voir le travail en détail") { ouvrirFenetre(id: "travail") }
                    .buttonStyle(.link)
            }
        }
    }

    private var recuperation: String {
        switch enCours.saisie {
        case .lien(_, let hote): "Depuis \(hote.montrable) (clone de quarantaine)."
        case .paquet: "Depuis pypi.org et files.pythonhosted.org."
        case .local(_, let nature): nature.detail
        default: "Copie en lecture seule dans la quarantaine."
        }
    }

    private func etape(_ e: Avancement.Etape, _ titre: String, detail: String?) -> some View {
        // Tant que l'accord est attendu, la lecture par IA n'a pas commencé.
        let active = enCours.etape == e && !(enCours.demande != nil && e == .regles)
        let passee = enCours.etape > e || (enCours.demande != nil && e == .regles)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if passee { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                else if active { ProgressView().controlSize(.small) }
                else { Image(systemName: "circle").foregroundStyle(.secondary) }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(titre).fontWeight(active ? .semibold : .regular).foregroundStyle(passee || active ? EgideTheme.encre : .secondary)
                if let detail, passee || active { Text(verbatim: detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    /// Accord demandé à chaque audit d'un dossier ou d'une archive du Mac, avec ce qui partirait.
    private func accord(_ a: LectureIA.Apercu) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Envoyer ce contenu à l'IA ?", systemImage: "hand.raised.fill").font(.headline).foregroundStyle(EgideTheme.bleu)
            Text("Il vient de ton Mac : rien ne part sans ton accord, donné pour cet audit seulement. Pour une app ou un fichier, ce sont ses textes et les fiches tirées de ses programmes (fonctions importées, textes trouvés, signature). Voici ce qui serait envoyé à anthropic.com (Claude Code verrouillé, sans outil ni connecteur, conversation non gardée) :")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Label("\(a.fichiers) fichier\(a.fichiers > 1 ? "s" : "") sur \(a.lisibles) lisible\(a.lisibles > 1 ? "s" : ""), dont \(a.enEntier) en entier", systemImage: "doc.on.doc")
                Label("\(ByteCountFormatter.string(fromByteCount: Int64(a.octets), countStyle: .file)) de texte, en \(a.lots) lot\(a.lots > 1 ? "s" : "")", systemImage: "shippingbox")
                Label(a.secretsMasques == 0 ? "Aucun secret en dur repéré dans ces fichiers" : "\(a.secretsMasques) secret\(a.secretsMasques > 1 ? "s" : "") masqué\(a.secretsMasques > 1 ? "s" : "") avant l'envoi",
                      systemImage: "key.slash")
            }
            .font(.callout)
            HStack {
                Button("Ne rien envoyer (règles seules)") { modele.repondre(false) }.buttonStyle(.egideSecondary)
                Button("Envoyer à anthropic.com") { modele.repondre(true) }.buttonStyle(.egide)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .egideCard()
    }
}

/// En-tête fixe au-dessus du contenu qui défile : le grand titre ne passe plus sous la barre de la fenêtre,
/// où il apparaissait en pâle à côté du titre de la fenêtre.
private struct PageAEnTete<Contenu: View>: View {
    let entete: EgideHeader<EmptyView>
    @ViewBuilder let contenu: Contenu

    init(_ entete: EgideHeader<EmptyView>, @ViewBuilder contenu: () -> Contenu) {
        self.entete = entete
        self.contenu = contenu()
    }

    var body: some View {
        VStack(spacing: 0) {
            entete
                .padding([.horizontal, .top], 24)
                .padding(.bottom, 12)
                .frame(maxWidth: 640)
            ScrollView {
                contenu
                    .padding([.horizontal, .bottom], 24)
                    .padding(.top, 6)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

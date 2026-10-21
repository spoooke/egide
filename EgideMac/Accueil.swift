import ArgosKit
import CerbereKit
import Charts
import EgideUI
import HephaistosKit
import PactoleKit
import MuseKit
import SwiftUI

/// Accueil : la date, l'état du Mac en grand, la semaine de Pactole à côté, les derniers audits de Cerbère dessous.
/// Chaque bloc ouvre l'onglet de son outil.
struct Accueil: View {
    @Bindable var etat: EtatEgide
    @State private var semaine: String?
    @State private var idees: String?
    @State private var machines: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Égide").font(.subheadline.weight(.medium)).foregroundStyle(EgideTheme.bleu)
                    Text(Self.date).font(.system(size: 34, weight: .bold, design: .rounded))
                }
                .padding(.top, 44)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        mac.frame(minWidth: 460)
                        colonne.frame(width: 300)
                    }
                    VStack(spacing: 18) { mac; colonne }
                }
                audits
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task {
            semaine = await PactoleKit.summary()
            idees = await MuseKit.summary()
            machines = await ArgosKit.summary()
        }
    }

    /// « Lundi 19 octobre ».
    private static var date: String {
        let texte = Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "fr_FR")))
        return texte.prefix(1).uppercased() + texte.dropFirst()
    }

    // MARK: Le Mac

    private var mac: some View {
        let modele = etat.hephaistos
        return Bloc("Ce Mac", action: "Détail") { etat.onglet = .hephaistos } contenu: {
            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(modele.chiffre)
                        .font(.system(size: 58, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(EgideTheme.bleu)
                    Text("\(modele.affichage.rawValue), sur 10 s").font(.caption).foregroundStyle(.secondary)
                }
                Chart(modele.historique) { point in
                    LineMark(x: .value("Heure", point.date), y: .value("°C", point.degres))
                        .foregroundStyle(EgideTheme.bleu)
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { AxisValueLabel() } }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 70)
            }
            if let releve = modele.releve {
                VStack(spacing: 10) {
                    if let memoire = releve.memoire { Jauge("Mémoire", memoire.texte, memoire.part) }
                    if let disque = releve.disque { Jauge("Disque", disque.texte, disque.part) }
                }
                .padding(.top, 6)
            }
        }
    }

    // MARK: Budget, idées, machines

    private var colonne: some View {
        VStack(spacing: 18) {
            pactole
            Bloc("Idées", action: "Muse") { etat.onglet = .muse } contenu: {
                Text(idees ?? "Rien en attente.").font(.callout)
            }
            Bloc("Machines", action: "Argos") { etat.onglet = .argos } contenu: {
                Text(machines ?? "Serveur Argos injoignable.").font(.callout)
            }
        }
    }

    private var pactole: some View {
        Bloc("Budget", action: "Pactole") { etat.onglet = .pactole } contenu: {
            Text(semaine ?? "…")
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Plafond de la semaine, du lundi au dimanche.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Cerbère

    private var audits: some View {
        Bloc("Derniers audits", action: "Cerbère") { etat.onglet = .cerbere } contenu: {
            let derniers = etat.cerbere.audits.prefix(5)
            if derniers.isEmpty {
                Text("Aucun audit pour l'instant. Coller un lien ou glisser un dossier dans Cerbère.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(derniers.enumerated()), id: \.element.id) { rang, audit in
                if rang > 0 { Divider() }
                Button {
                    etat.cerbere.selection = audit.id
                    etat.onglet = .cerbere
                } label: {
                    HStack(spacing: 10) {
                        Circle().fill(audit.rapport.verdict.couleur).frame(width: 8, height: 8)
                        Text(verbatim: audit.rapport.nomCourt.montrable).lineLimit(1)
                        Spacer()
                        Text(audit.rapport.verdict.titre).foregroundStyle(.secondary)
                        Text(audit.rapport.date.formatted(.relative(presentation: .named)))
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .trailing)
                    }
                    .font(.callout)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Bloc de l'accueil : titre à gauche, lien vers l'outil à droite, contenu dessous.
private struct Bloc<Contenu: View>: View {
    let titre: String
    let action: String
    let ouvrir: () -> Void
    let contenu: Contenu

    init(_ titre: String, action: String, ouvrir: @escaping () -> Void, @ViewBuilder contenu: () -> Contenu) {
        self.titre = titre
        self.action = action
        self.ouvrir = ouvrir
        self.contenu = contenu()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(titre).font(.headline)
                Spacer()
                Button(action: ouvrir) {
                    Label(action, systemImage: "arrow.up.right").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(EgideTheme.bleu)
            }
            contenu
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .egideCard(padding: 20, cornerRadius: 24)
    }
}

/// Nom et valeur au-dessus d'une barre fine.
private struct Jauge: View {
    let nom: String
    let valeur: String
    let part: Double

    init(_ nom: String, _ valeur: String, _ part: Double) {
        self.nom = nom
        self.valeur = valeur
        self.part = part
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(nom)
                Spacer()
                Text(valeur).foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout)
            GeometryReader { geo in
                Capsule().fill(EgideTheme.bleu.opacity(0.12))
                    .overlay(alignment: .leading) {
                        Capsule().fill(part > 0.9 ? .orange : EgideTheme.bleu).frame(width: geo.size.width * part)
                    }
            }
            .frame(height: 5)
        }
    }
}

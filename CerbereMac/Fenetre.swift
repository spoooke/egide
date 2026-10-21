import CerbereKit
import EgideUI
import SwiftUI

/// Cerbère : nouvel audit et historique à gauche, rapport ou avancement à droite.
struct Fenetre: View {
    @Bindable var modele: Modele
    /// Vrai dans l'onglet d'Égide : la liste devient une carte posée sur le fond, sans barre latérale du système.
    var enOnglet = false
    @Environment(\.openWindow) private var ouvrirFenetre

    var body: some View {
        Group {
            if enOnglet {
                HStack(alignment: .top, spacing: 0) {
                    liste
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .frame(width: 270)
                        .egideCard(padding: 6, cornerRadius: 22)
                        .padding(.leading, 18)
                        .padding(.top, 38)
                        .padding(.bottom, 14)
                    detail
                        .padding(.top, 26)
                        .tint(EgideTheme.bleu)
                }
            } else {
                NavigationSplitView {
                    liste.navigationSplitViewColumnWidth(min: 230, ideal: 270)
                } detail: {
                    detail.egideScreen()
                }
            }
        }
        .onChange(of: modele.selection) { modele.comparaison = nil }
        // L'outil en ligne de commande range ses rapports au même endroit : la liste est relue au retour dans l'app.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in modele.relire() }
        // Audits lancés ailleurs (iPhone, outil) : signalés dans la barre latérale, et l'historique se met à jour à leur fin.
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in modele.surveiller() }
    }

    private var liste: some View {
        List(selection: $modele.selection) {
            Label(modele.enCours == nil ? "Nouvel audit" : "Audit en cours…", systemImage: modele.enCours == nil ? "plus.circle" : "hourglass")
                .tag(Modele.nouveau)
            Button { ouvrirFenetre(id: "travail") } label: {
                Label(modele.auditsAilleurs > 0 ? "Travail en cours (\(modele.auditsAilleurs) ailleurs)" : "Travail en cours",
                      systemImage: modele.auditsAilleurs > 0 ? "waveform.path.ecg" : "list.bullet.rectangle")
            }
            .buttonStyle(.plain)
            .help("Journal en direct des audits : app, outil cerbere et demandes de l'iPhone (⌘J)")
            Section("Historique") {
                ForEach(modele.audits) { audit in
                    LigneAudit(audit: audit)
                        .tag(audit.id)
                        .contextMenu { Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([audit.dossier]) } }
                }
            }
        }
    }

    private var detail: some View {
        Group {
            if let c = modele.comparaison {
                VueComparaison(ancien: c.ancien, nouveau: c.nouveau) { modele.comparaison = nil }
            } else if let audit = modele.auditChoisi {
                VueRapport(audit: audit, modele: modele).id(audit.id)
            } else if let enCours = modele.enCours {
                VueAvancement(enCours: enCours, modele: modele)
            } else {
                VueNouvelAudit(modele: modele)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(EgideTheme.encre)
    }
}

private struct LigneAudit: View {
    let audit: AuditGarde

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(audit.rapport.verdict.couleur).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: audit.rapport.nomCourt.montrable).lineLimit(1)
                Text(verbatim: "\(audit.rapport.date.formatted(date: .numeric, time: .shortened)) · \(audit.rapport.couches.ia ? "règles + IA" : "règles seules")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("\(audit.rapport.nomCourt.montrable), \(audit.rapport.verdict.titre)")
    }
}

import AppKit
import CryptoKit
import EgideUI
import SwiftUI

/// Hermès sur le Mac : l'état de l'agent, les iPhone autorisés et le journal des sessions, en lecture seule.
/// L'agent reste une app à part : lui seul a le droit d'enregistrer l'écran et de piloter le Mac, et lui seul
/// appaire ou révoque un iPhone (il garde la clé du Mac). Égide ne fait que l'ouvrir.
struct HermesMac: View {
    @State private var etat = EtatHermes.lire()

    var body: some View {
        Onglet.page(.hermes) {
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 18) {
                    appareils
                    journal
                }
                .frame(maxWidth: .infinity)
                agent.frame(width: 300)
            }
            .frame(maxWidth: 976)
        }
        .task {
            while !Task.isCancelled {
                etat = EtatHermes.lire()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var agent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent").font(.headline)
            HStack(spacing: 8) {
                Circle().fill(etat.enMarche ? .green : .secondary).frame(width: 8, height: 8)
                Text(etat.enMarche ? "En marche" : "Arrêté")
            }
            if etat.enMarche {
                Text(etat.connexionsAcceptees ? "Accepte les connexions des iPhone autorisés." : "Connexions coupées.")
                    .foregroundStyle(etat.connexionsAcceptees ? Color.secondary : Color.orange)
            }
            Divider()
            if etat.app == nil {
                Text("Hermès n'est pas installé sur ce Mac.").foregroundStyle(.secondary)
            } else {
                Button(etat.enMarche ? "Ouvrir le panneau d'Hermès" : "Lancer Hermès") { ouvrirAgent() }
                    .buttonStyle(.borderedProminent)
                Text("Appairer un iPhone, couper la session ou révoquer un appareil se fait dans le panneau d'Hermès.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .egideCard(padding: 20, cornerRadius: 24)
    }

    private var appareils: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("iPhone autorisés").font(.headline)
            if etat.appareils.isEmpty {
                Text("Aucun appareil appairé.").foregroundStyle(.secondary)
            }
            ForEach(Array(etat.appareils.enumerated()), id: \.element.empreinte) { rang, appareil in
                if rang > 0 { Divider() }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appareil.nom)
                        Text("Empreinte \(appareil.empreinte) · appairé le \(appareil.ajoute.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    Text(appareil.vu.map { "vu \($0.formatted(.relative(presentation: .named)))" } ?? "jamais connecté")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .egideCard(padding: 20, cornerRadius: 24)
    }

    private var journal: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Dernières sessions").font(.headline)
                Spacer()
                Button("Journal complet") { NSWorkspace.shared.open(EtatHermes.journal) }
                    .buttonStyle(.plain).foregroundStyle(EgideTheme.bleu)
            }
            if etat.journal.isEmpty {
                Text("Rien pour l'instant.").foregroundStyle(.secondary)
            }
            ForEach(Array(etat.journal.enumerated()), id: \.offset) { _, ligne in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(ligne.date?.formatted(date: .abbreviated, time: .shortened) ?? "")
                        .foregroundStyle(.secondary)
                        .frame(width: 150, alignment: .leading)
                    Text(ligne.texte).lineLimit(1)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .egideCard(padding: 20, cornerRadius: 24)
    }

    /// Relancer une app déjà ouverte lui fait afficher son panneau de contrôle (applicationShouldHandleReopen).
    private func ouvrirAgent() {
        guard let app = etat.app else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Ce qu'Égide lit de l'agent : rien n'est écrit, la clé du Mac (identity.key) n'est jamais ouverte.
struct EtatHermes {
    struct Appareil {
        let nom: String
        let empreinte: String
        let ajoute: Date
        let vu: Date?
    }

    struct Ligne {
        let date: Date?
        let texte: String
    }

    static let identifiant = "com.sgillio.swiftview.mac"
    /// Dossier de l'agent (il garde son nom d'avant Hermès).
    static let dossier = URL.applicationSupportDirectory.appending(path: "Swiftview")
    static let journal = dossier.appending(path: "journal.log")

    var app: URL?
    var enMarche = false
    var connexionsAcceptees = true
    var appareils: [Appareil] = []
    var journal: [Ligne] = []

    static func lire() -> EtatHermes {
        if EgideDemo.actif { return demo }
        var etat = EtatHermes()
        etat.app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifiant)
        etat.enMarche = !NSRunningApplication.runningApplications(withBundleIdentifier: identifiant).isEmpty
        etat.connexionsAcceptees = UserDefaults.standard.persistentDomain(forName: identifiant)?["connectionsEnabled"] as? Bool ?? true
        etat.appareils = appareils()
        etat.journal = dernieresLignes(8)
        return etat
    }

    /// Mode démo : un iPhone appairé et quelques sessions inventées, sans lire le dossier de l'agent.
    static var demo: EtatHermes {
        let heure = 3_600.0
        var etat = EtatHermes()
        etat.app = URL(filePath: "/Applications/Hermes.app")
        etat.enMarche = true
        etat.appareils = [Appareil(nom: "iPhone-Demo", empreinte: "4F2A-91C0-7B3E", ajoute: .now.addingTimeInterval(-40 * 24 * heure),
                                   vu: .now.addingTimeInterval(-3 * heure))]
        etat.journal = [
            Ligne(date: .now.addingTimeInterval(-3 * heure), texte: "Session fermée (iPhone-Demo)"),
            Ligne(date: .now.addingTimeInterval(-3.4 * heure), texte: "SESSION OUVERTE : iPhone-Demo, réseau local"),
            Ligne(date: .now.addingTimeInterval(-27 * heure), texte: "Session fermée (iPhone-Demo)"),
            Ligne(date: .now.addingTimeInterval(-28 * heure), texte: "SESSION OUVERTE : iPhone-Demo, à distance"),
        ]
        return etat
    }

    /// Même format que TrustedDevice dans l'agent (trusted-devices.json).
    private struct Autorise: Decodable {
        var name: String
        var publicKey: Data
        var added: Date
        var lastSeen: Date?
    }

    private static func appareils() -> [Appareil] {
        guard let data = try? Data(contentsOf: dossier.appending(path: "trusted-devices.json")),
              let liste = try? JSONDecoder().decode([Autorise].self, from: data) else { return [] }
        return liste.map { Appareil(nom: $0.name, empreinte: empreinte($0.publicKey), ajoute: $0.added, vu: $0.lastSeen) }
    }

    /// Empreinte affichée par l'agent et par l'iPhone : 6 premiers octets du SHA-256, par groupes de 4 caractères.
    static func empreinte(_ cle: Data) -> String {
        let hex = SHA256.hash(data: cle).prefix(6).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { i in
            let debut = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[debut..<hex.index(debut, offsetBy: 4)])
        }.joined(separator: "-")
    }

    /// Les dernières lignes du journal, la plus récente en haut. Format : « date ISO 8601, deux espaces, texte ».
    private static func dernieresLignes(_ nombre: Int) -> [Ligne] {
        guard let texte = try? String(contentsOf: journal, encoding: .utf8) else { return [] }
        let format = ISO8601DateFormatter()
        return texte.split(separator: "\n").suffix(nombre).reversed().map { ligne in
            let parties = ligne.split(separator: "  ", maxSplits: 1)
            guard parties.count == 2, let date = format.date(from: String(parties[0])) else { return Ligne(date: nil, texte: String(ligne)) }
            return Ligne(date: date, texte: String(parties[1]))
        }
    }
}

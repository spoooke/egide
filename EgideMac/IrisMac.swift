import EgideUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Iris sur le Mac : les scans que l'iPhone copie dans un dossier (iCloud Drive › Iris, par exemple),
/// rangés par genre (Tickets, Factures, Documents). On les retrouve, on les regarde, on les ouvre.
/// Le scan lui-même se fait sur l'iPhone.
struct IrisMac: View {
    @AppStorage("iris.mac.signetDossier") private var signet: Data?
    @State private var scans: [ScanRange] = []
    @State private var genre: String?
    @State private var recherche = ""
    @State private var apercu: URL?
    @State private var choix = false

    private static let genres = ["Tickets", "Factures", "Documents"]

    var body: some View {
        Onglet.page(.iris) {
            if let dossier {
                barre(dossier)
                liste
            } else {
                vide
            }
        }
        .fileImporter(isPresented: $choix, allowedContentTypes: [.folder]) { resultat in
            guard case .success(let url) = resultat else { return }
            signet = try? url.bookmarkData()
            relire()
        }
        .quickLookPreview($apercu, in: visibles.map(\.url))
        .task(id: signet) { relire() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in relire() }
    }

    private var dossier: URL? {
        if EgideDemo.actif { return URL(filePath: "/demo/Iris") }
        var perime = false
        return signet.flatMap { try? URL(resolvingBookmarkData: $0, bookmarkDataIsStale: &perime) }
    }

    private var visibles: [ScanRange] {
        scans.filter { scan in
            (genre == nil || scan.genre == genre)
                && (recherche.isEmpty || scan.nom.localizedStandardContains(recherche))
        }
    }

    private var vide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choisis le dossier où l'iPhone copie les scans (Réglages d'Iris › Copie pour le Mac).")
                .foregroundStyle(.secondary)
            Button("Choisir le dossier…") { choix = true }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .egideCard(padding: 20, cornerRadius: 24)
    }

    private func barre(_ dossier: URL) -> some View {
        HStack(spacing: 12) {
            Picker("Genre", selection: $genre) {
                Text("Tout").tag(String?.none)
                ForEach(Self.genres, id: \.self) { Text($0).tag(Optional($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            TextField("Chercher un nom", text: $recherche)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Spacer()
            Button("Afficher dans le Finder", systemImage: "folder") { NSWorkspace.shared.open(dossier) }
            Button("Changer de dossier…") { choix = true }
        }
        .frame(maxWidth: 976)
    }

    private var liste: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if visibles.isEmpty {
                    Text(scans.isEmpty ? "Aucun scan dans ce dossier pour l'instant." : "Aucun scan ne correspond.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }
                ForEach(Array(visibles.enumerated()), id: \.element.id) { rang, scan in
                    if rang > 0 { Divider() }
                    ligne(scan)
                }
            }
            .egideCard(padding: 18, cornerRadius: 24)
            .padding(.bottom, 32)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: 976)
    }

    private func ligne(_ scan: ScanRange) -> some View {
        HStack(spacing: 12) {
            Image(systemName: scan.symbole).foregroundStyle(EgideTheme.bleu).frame(width: 22)
            Text(scan.nom).lineLimit(1)
            Spacer()
            Text(scan.genre ?? "Sans genre").foregroundStyle(.secondary)
            Text(scan.date.formatted(date: .abbreviated, time: .omitted))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 8)
        .contentShape(.rect)
        .onTapGesture(count: 2) { NSWorkspace.shared.open(scan.url) }
        .onTapGesture { apercu = scan.url }
        .contextMenu {
            Button("Ouvrir") { NSWorkspace.shared.open(scan.url) }
            Button("Coup d'œil") { apercu = scan.url }
            Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([scan.url]) }
        }
        .help("Clic : coup d'œil. Double-clic : ouvrir.")
    }

    private func relire() {
        if EgideDemo.actif { scans = ScanRange.demo; return }
        guard let dossier else { scans = []; return }
        let racine = ScanRange.pdfs(dans: dossier, genre: nil)
        let ranges = Self.genres.flatMap { ScanRange.pdfs(dans: dossier.appending(path: $0), genre: $0) }
        scans = (racine + ranges).sorted { $0.date > $1.date }
    }
}

/// Un PDF du dossier d'Iris. `genre` : nom du sous-dossier, nil pour un PDF posé à la racine.
struct ScanRange: Identifiable {
    let url: URL
    let genre: String?
    let date: Date
    var id: URL { url }
    var nom: String { url.deletingPathExtension().lastPathComponent }

    var symbole: String {
        switch genre {
        case "Tickets": "receipt"
        case "Factures": "doc.text"
        default: "doc"
        }
    }

    /// Mode démo : des scans inventés (aucun fichier derrière).
    static var demo: [ScanRange] {
        let jour = 86_400.0
        let lignes: [(String, String?, Double)] = [
            ("Ticket 2026-10-18 Supermarché", "Tickets", 1), ("Facture 2026-10-15 Électricité", "Factures", 4),
            ("Ticket 2026-10-14 Pharmacie", "Tickets", 5), ("Document 2026-10-10 Contrat de location", "Documents", 9),
            ("Facture 2026-10-02 Internet", "Factures", 17), ("Document 2026-09-28 Attestation d'assurance", "Documents", 21),
        ]
        return lignes.map { ScanRange(url: URL(filePath: "/demo/Iris/\($0.0).pdf"), genre: $0.1, date: .now.addingTimeInterval(-$0.2 * jour)) }
    }

    static func pdfs(dans dossier: URL, genre: String?) -> [ScanRange] {
        let fichiers = (try? FileManager.default.contentsOfDirectory(at: dossier, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
        return fichiers.filter { $0.pathExtension.lowercased() == "pdf" }.map { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ScanRange(url: url, genre: genre, date: date)
        }
    }
}

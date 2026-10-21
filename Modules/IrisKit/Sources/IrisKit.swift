import EgideUI
import PhotosUI
import SwiftUI

/// App Iris d'Égide : scanner un ticket, une feuille ou un document et l'envoyer par mail.
/// Tout est lu sur l'iPhone ; seul le mail part, par la fenêtre Mail d'iOS.
public enum IrisKit {
    public static let title = "Iris"
    public static let systemImage = "doc.viewfinder"
}

/// Écran ouvert par un lien egide://iris/…
public enum IrisRoute: Equatable {
    case home
    case reglages
    /// Fichiers passés par l'extension de partage (IrisColis).
    case partage

    public init(path: [String]) {
        switch path.first {
        case "reglages": self = .reglages
        case "partage": self = .partage
        default: self = .home
        }
    }
}

/// Écran racine de l'onglet : scanner, ou importer une photo, puis liste des PDF prêts à joindre.
/// `path` : chemin du dernier lien egide://iris/… reçu ; `request` change à chaque lien, même identique au précédent.
public struct IrisRootView: View {
    private enum Ecran: Hashable {
        case reglages
        case historique
        case scan(IrisScan)
    }

    private let path: [String]
    private let request: Int
    private let onHome: (@MainActor @Sendable () -> Void)?
    private let scans = IrisScans()
    @State private var ouverts: [Ecran] = []
    @State private var reglages = IrisReglages()
    @AppStorage("iris.choix") private var choix = IrisChoixGenre.auto
    @State private var liste: [IrisScan] = []
    @State private var scanner = false
    @State private var choixFichier = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var enCours = false
    @State private var aCadrer: [IrisImport] = []
    @State private var erreur: String?
    @State private var titreErreur = "Scan impossible"
    @State private var aEnvoyer: IrisScan?
    @State private var envois: [IrisEnvoi] = []

    /// `onHome` : bouton « Précédent » vers l'accueil d'Égide.
    public init(path: [String] = [], request: Int = 0, onHome: (@MainActor @Sendable () -> Void)? = nil) {
        self.path = path
        self.request = request
        self.onHome = onHome
    }

    public var body: some View {
        NavigationStack(path: $ouverts) {
            List {
                Group {
                    if !reglages.complet {
                        Section {
                            Button { ouverts = [.reglages] } label: {
                                Label("Saisis les adresses où envoyer les scans", systemImage: "envelope.badge")
                            }
                        }
                    }
                    sectionNouveau
                    if !liste.isEmpty { sectionScans }
                    if !envois.isEmpty {
                        Section {
                            Button { ouverts = [.historique] } label: {
                                LabeledContent {
                                    Text(envois[0].resultat.titre)
                                } label: {
                                    Label("Historique des envois", systemImage: "clock")
                                }
                            }
                        }
                    }
                }
                .egideRow()
            }
            .egideList()
            .foregroundStyle(EgideTheme.encre)
            .navigationTitle(IrisKit.title)
            .toolbar {
                HomeToolbarItem(action: onHome)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Réglages", systemImage: "gearshape") { ouverts = [.reglages] }
                }
            }
            .navigationDestination(for: Ecran.self) { ecran in
                switch ecran {
                case .reglages: VueReglages()
                case .historique: VueHistorique(envois: envois)
                case .scan(let scan):
                    VueScanOuvert(scan: scan, envoyer: { aEnvoyer = scan }, changer: { changer(scan, en: $0) })
                }
            }
            .fullScreenCover(isPresented: $scanner) {
                VueScanner { pages in
                    scanner = false
                    traiter(pages)
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: Binding { !aCadrer.isEmpty } set: { if !$0 { aCadrer = [] } }) {
                VueCadrage(imports: aCadrer) { coins in
                    let imports = aCadrer
                    aCadrer = []
                    if let coins { redresser(imports, coins: coins) } else { enCours = false }
                }
            }
            .fileImporter(isPresented: $choixFichier, allowedContentTypes: [.image], allowsMultipleSelection: true) { resultat in
                guard case .success(let urls) = resultat else { return }
                importer(urls.compactMap { url in
                    let acces = url.startAccessingSecurityScopedResource()
                    defer { if acces { url.stopAccessingSecurityScopedResource() } }
                    return try? Data(contentsOf: url)
                })
            }
            .onChange(of: photos) { _, items in
                guard !items.isEmpty else { return }
                photos = []
                enCours = true
                Task {
                    var pages: [Data] = []
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self) { pages.append(data) }
                    }
                    importer(pages)
                }
            }
            .onChange(of: request, initial: true) {
                switch IrisRoute(path: path) {
                case .reglages: ouverts = [.reglages]
                case .partage: recevoirPartage()
                case .home: break
                }
            }
            // Relu au retour des réglages ou d'un scan.
            .onChange(of: ouverts, initial: true) {
                reglages = .charger()
                liste = scans.liste()
                envois = IrisHistorique().liste()
            }
        }
        // Sur la pile entière : les alertes et la fenêtre Mail s'ouvrent aussi depuis un scan ouvert.
        .alert(titreErreur, isPresented: Binding { erreur != nil } set: { if !$0 { erreur = nil } }) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(erreur ?? "")
        }
        .envoiScan($aEnvoyer, ouvrirReglages: { ouverts = [.reglages] }) {
            envois = IrisHistorique().liste()
        }
    }

    private var sectionNouveau: some View {
        Section {
            Picker("Genre", selection: $choix) {
                ForEach(IrisChoixGenre.allCases, id: \.self) { Text($0.titre).tag($0) }
            }
            .pickerStyle(.segmented)
            if enCours {
                HStack {
                    ProgressView()
                    Text("Lecture du texte…")
                }
            } else {
                if VueScanner.disponible {
                    Button { scanner = true } label: {
                        Label("Scanner", systemImage: IrisKit.systemImage)
                    }
                }
                PhotosPicker(selection: $photos, maxSelectionCount: 20, selectionBehavior: .ordered, matching: .images) {
                    Label("Choisir dans Photos", systemImage: "photo.on.rectangle")
                }
                Button { choixFichier = true } label: {
                    Label("Choisir dans Fichiers", systemImage: "folder")
                }
            }
        } header: {
            Text("Nouveau scan")
        } footer: {
            Text("Une page par image. Le texte est lu sur l'iPhone : on peut le chercher dans le PDF. En Auto, Iris y reconnaît un ticket ou une facture ; sinon c'est un document. Le genre se corrige sur le scan ouvert.")
        }
    }

    private var sectionScans: some View {
        Section("Scans") {
            ForEach(liste) { scan in
                Button { ouverts = [.scan(scan)] } label: {
                    LabeledContent {
                        Text(scan.date, format: .dateTime.hour().minute())
                    } label: {
                        Label(scan.nom, systemImage: "doc.richtext")
                    }
                }
            }
            .onDelete { index in
                for i in index { try? scans.supprimer(liste[i]) }
                liste = scans.liste()
            }
        }
    }

    /// Fichiers partagés depuis Photos ou Fichiers : images vers le cadrage, PDF rangés tels quels puis proposés à l'envoi.
    private func recevoirPartage() {
        let tri = IrisPartage.trier(IrisColis.retirer())
        var ranges: [IrisScan] = []
        for pdf in tri.pdfs {
            if let scan = try? scans.ranger(pdf) { ranges.append(scan) }
        }
        liste = scans.liste()
        Task { await IrisCopieMac().copier(ranges) }
        if !tri.images.isEmpty {
            ouverts = []
            importer(tri.images)
        } else if let scan = ranges.first {
            ouverts = [.scan(scan)]
            aEnvoyer = scan
        } else if !tri.refuses.isEmpty {
            titreErreur = "Fichier non pris"
            erreur = "Iris prend les photos et les PDF. Écarté : " + tri.refuses.joined(separator: ", ") + "."
        }
    }

    /// Pages du scanner (déjà redressées) → PDF daté, enregistré puis ouvert.
    private func traiter(_ images: [Data]) {
        guard !images.isEmpty else { enCours = false; return }
        enCours = true
        Task {
            await enregistrer {
                var pages: [IrisPage] = []
                for image in images { pages.append(try await IrisImage.page(de: image)) }
                return pages
            }
        }
    }

    /// Photos importées : bords cherchés sur chaque image, puis écran de cadrage.
    private func importer(_ images: [Data]) {
        guard !images.isEmpty else { enCours = false; return }
        enCours = true
        Task {
            do {
                var imports: [IrisImport] = []
                for data in images {
                    let image = try IrisImage.image(de: data)
                    imports.append(IrisImport(image: image, detectes: await IrisCadrage.detecter(image)))
                }
                aCadrer = imports
            } catch {
                enCours = false
                titreErreur = "Scan impossible"
                erreur = error.localizedDescription
            }
        }
    }

    /// Images cadrées → redressées → PDF.
    private func redresser(_ imports: [IrisImport], coins: [IrisCoins]) {
        Task {
            await enregistrer {
                var pages: [IrisPage] = []
                for (photo, coins) in zip(imports, coins) {
                    pages.append(try await IrisImage.page(de: try IrisCadrage.redresser(photo.image, coins: coins)))
                }
                return pages
            }
        }
    }

    /// Genre corrigé sur le scan ouvert : PDF renommé, copie pour le Mac rangée dans le bon sous-dossier.
    private func changer(_ scan: IrisScan, en genre: IrisGenre) {
        do {
            let nouveau = try scans.changer(scan, en: genre)
            liste = scans.liste()
            ouverts = [.scan(nouveau)]
            Task { await IrisCopieMac().deplacer(scan, vers: nouveau) }
        } catch {
            titreErreur = "Genre inchangé"
            erreur = error.localizedDescription
        }
    }

    /// Pages → PDF daté, enregistré, ouvert, puis envoyé.
    private func enregistrer(_ pages: () async throws -> [IrisPage]) async {
        defer { enCours = false }
        do {
            let pages = try await pages()
            let scan = try scans.enregistrer(pages, genre: IrisClasseur.genre(pages, choix: choix))
            liste = scans.liste()
            // Copie dans Photos si le réglage le demande (rien sinon), avant la fenêtre Mail : la demande
            // d'accès d'iOS, la première fois, ne se mêle pas au mail.
            await IrisCopiePhotos.copier(pages, reglages: IrisReglages.charger())
            // Copie pour le Mac si un dossier est choisi (rien sinon) ; un échec n'empêche pas l'envoi.
            await IrisCopieMac().copier([scan])
            ouverts = [.scan(scan)]
            aEnvoyer = scan
        } catch {
            titreErreur = "Scan impossible"
            erreur = error.localizedDescription
        }
    }
}

// Services pour l'app : résumé de l'Accueil, sauvegarde globale.
extension IrisKit {
    /// Une ligne sous la tuile de l'Accueil (nil : rien à afficher).
    @MainActor
    public static func summary() async -> String? {
        IrisReglages.charger().complet ? nil : "Destinataires à saisir"
    }

    /// Données du module pour la sauvegarde globale : les réglages (adresses comprises, jamais de secret).
    @MainActor
    public static func backup() throws -> Data? {
        try JSONEncoder().encode(IrisReglages.charger())
    }

    /// Restaure les données de backup() ; renvoie un compte rendu court.
    @MainActor
    public static func restore(_ data: Data) throws -> String {
        let reglages = try JSONDecoder().decode(IrisReglages.self, from: data)
        reglages.enregistrer()
        return "réglages restaurés"
    }
}

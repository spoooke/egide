import PDFKit
import SwiftUI
import VisionKit

/// Appareil photo « document » d'iOS : bords détectés, image redressée, plusieurs pages.
/// Renvoie chaque page en JPEG (pleine qualité, réduite ensuite par IrisImage), ou [] si on annule.
struct VueScanner: UIViewControllerRepresentable {
    let fin: @MainActor ([Data]) -> Void

    static var disponible: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinateur { Coordinateur(fin: fin) }

    @MainActor
    final class Coordinateur: NSObject, @MainActor VNDocumentCameraViewControllerDelegate {
        let fin: @MainActor ([Data]) -> Void

        init(fin: @escaping @MainActor ([Data]) -> Void) { self.fin = fin }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let pages = (0..<scan.pageCount).compactMap { scan.imageOfPage(at: $0).jpegData(compressionQuality: 0.9) }
            fin(pages)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { fin([]) }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { fin([]) }
    }
}

/// Aperçu d'un PDF.
struct VuePDF: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let vue = PDFView()
        vue.autoScales = true
        vue.backgroundColor = .clear
        vue.document = PDFDocument(url: url)
        return vue
    }

    func updateUIView(_ vue: PDFView, context: Context) {
        if vue.document?.documentURL != url { vue.document = PDFDocument(url: url) }
    }
}

/// Un scan ouvert : aperçu du PDF, bouton pour l'envoyer.
struct VueScanOuvert: View {
    let scan: IrisScan
    let envoyer: () -> Void
    /// Correction du genre : le PDF est renommé.
    let changer: (IrisGenre) -> Void

    var body: some View {
        VuePDF(url: scan.url)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(scan.nom)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Genre", systemImage: "tag") {
                        Picker("Genre", selection: Binding { IrisGenre(nom: scan.nom) } set: { if let genre = $0 { changer(genre) } }) {
                            ForEach(IrisGenre.allCases, id: \.self) { Text($0.titre).tag(Optional($0)) }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Envoyer", systemImage: "paperplane", action: envoyer)
                }
            }
    }
}

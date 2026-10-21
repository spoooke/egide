import EgideUI
import MessageUI
import SwiftUI
import UIKit

/// Fenêtre Mail d'iOS pré-remplie : rien ne part sans un appui sur Envoyer.
struct VueMail: UIViewControllerRepresentable {
    let scan: IrisScan
    let reglages: IrisReglages
    let fin: @MainActor (IrisResultat) -> Void

    static var disponible: Bool { MFMailComposeViewController.canSendMail() }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let mail = MFMailComposeViewController()
        mail.mailComposeDelegate = context.coordinator
        mail.setToRecipients(reglages.adresses)
        mail.setSubject(IrisMail.objet(reglages, scan: scan))
        if let pdf = try? Data(contentsOf: scan.url) {
            mail.addAttachmentData(pdf, mimeType: "application/pdf", fileName: scan.url.lastPathComponent)
        }
        return mail
    }

    func updateUIViewController(_ mail: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinateur { Coordinateur(fin: fin) }

    @MainActor
    final class Coordinateur: NSObject, @MainActor MFMailComposeViewControllerDelegate {
        let fin: @MainActor (IrisResultat) -> Void

        init(fin: @escaping @MainActor (IrisResultat) -> Void) { self.fin = fin }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            fin(error == nil ? IrisResultat(result) : .echec)
        }
    }
}

/// Feuille de partage d'iOS avec le PDF, en secours quand l'iPhone n'a pas de compte Mail.
struct VuePartage: UIViewControllerRepresentable {
    let url: URL
    let fin: @MainActor (IrisResultat) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let partage = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        partage.completionWithItemsHandler = { _, fait, _, erreur in
            Task { @MainActor in fin(erreur != nil ? .echec : fait ? .partage : .annule) }
        }
        return partage
    }

    func updateUIViewController(_ partage: UIActivityViewController, context: Context) {}
}

/// Envoi d'un scan : Mail, secours ou réglages selon IrisMail.voie ; chaque issue va dans l'historique.
/// Mettre un scan dans `scan` lance l'envoi ; il revient à nil à la fin.
private struct EnvoiScan: ViewModifier {
    private enum Fenetre: Identifiable {
        case mail(IrisScan, IrisReglages)
        case partage(IrisScan)

        var id: String {
            switch self {
            case .mail(let scan, _): "mail " + scan.url.path
            case .partage(let scan): "partage " + scan.url.path
            }
        }

        var scan: IrisScan {
            switch self {
            case .mail(let scan, _), .partage(let scan): scan
            }
        }
    }

    private enum Alerte {
        case pasDeMail(IrisScan)
        case reglages
    }

    @Binding var scan: IrisScan?
    let ouvrirReglages: () -> Void
    let fini: () -> Void
    @State private var fenetre: Fenetre?
    @State private var alerte: Alerte?

    func body(content: Content) -> some View {
        content
            .onChange(of: scan, initial: true) {
                guard let scan else { return }
                let reglages = IrisReglages.charger()
                switch IrisMail.voie(reglages, peutEnvoyer: VueMail.disponible) {
                case .mail: fenetre = .mail(scan, reglages)
                case .secours: alerte = .pasDeMail(scan)
                case .reglages: alerte = .reglages
                }
            }
            .sheet(item: $fenetre, onDismiss: { scan = nil }) { fenetre in
                switch fenetre {
                case .mail(let scan, let reglages):
                    VueMail(scan: scan, reglages: reglages) { noter(fenetre.scan, $0) }
                        .ignoresSafeArea()
                case .partage(let scan):
                    VuePartage(url: scan.url) { noter(fenetre.scan, $0) }
                        .presentationDetents([.medium, .large])
                        .ignoresSafeArea()
                }
            }
            .alert(titreAlerte, isPresented: Binding { alerte != nil } set: { if !$0 { alerte = nil } }, presenting: alerte) { alerte in
                switch alerte {
                case .pasDeMail(let scan):
                    Button("Partager le PDF") { fenetre = .partage(scan) }
                    Button("Plus tard", role: .cancel) { self.scan = nil }
                case .reglages:
                    Button("Ouvrir les réglages") { self.scan = nil; ouvrirReglages() }
                    Button("Plus tard", role: .cancel) { self.scan = nil }
                }
            } message: { alerte in
                switch alerte {
                case .pasDeMail:
                    Text("Aucun compte n'est configuré dans l'app Mail de l'iPhone. Ajoute-le dans Réglages › Apps › Mail › Comptes, ou partage le PDF autrement.")
                case .reglages:
                    Text("Saisis dans les réglages d'Iris les adresses où envoyer les scans.")
                }
            }
    }

    private var titreAlerte: String {
        switch alerte {
        case .pasDeMail: "Mail n'est pas configuré"
        case .reglages, nil: "Destinataires à saisir"
        }
    }

    private func noter(_ scan: IrisScan, _ resultat: IrisResultat) {
        IrisHistorique().ajouter(IrisEnvoi(nom: scan.nom, pages: scan.pages, resultat: resultat))
        fenetre = nil
        fini()
    }
}

extension View {
    /// Envoi du scan placé dans `scan` ; `fini` est appelé après chaque issue notée dans l'historique.
    func envoiScan(_ scan: Binding<IrisScan?>, ouvrirReglages: @escaping () -> Void, fini: @escaping () -> Void = {}) -> some View {
        modifier(EnvoiScan(scan: scan, ouvrirReglages: ouvrirReglages, fini: fini))
    }
}

/// Historique des envois : nom du scan, date, pages, issue (jamais les adresses).
struct VueHistorique: View {
    let envois: [IrisEnvoi]

    var body: some View {
        List {
            ForEach(envois) { envoi in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(envoi.nom)
                        Text("\(envoi.date.formatted(date: .abbreviated, time: .shortened)) · \(envoi.pages) page\(envoi.pages > 1 ? "s" : "")")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(envoi.resultat.titre, systemImage: envoi.resultat.systemImage)
                }
                .egideRow()
            }
        }
        .egideList()
        .foregroundStyle(EgideTheme.encre)
        .navigationTitle("Envois")
        .navigationBarTitleDisplayMode(.inline)
    }
}

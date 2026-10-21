import EgideUI
import SwiftUI

/// Réglages d'Iris : destinataires, objet du mail, copie dans Photos et pour le Mac. Enregistrés à chaque changement.
struct VueReglages: View {
    @State private var reglages = IrisReglages.charger()
    private let copieMac = IrisCopieMac()
    @State private var dossierMac = IrisCopieMac().nomDossier
    @State private var erreurMac = IrisCopieMac().erreur
    @State private var choixDossier = false
    @State private var copieEnCours = false
    @State private var compteRendu: String?

    var body: some View {
        List {
            Group {
                Section {
                    ForEach(0..<IrisReglages.nombreDestinataires, id: \.self) { index in
                        champAdresse(index)
                    }
                } header: {
                    Text("Destinataires")
                } footer: {
                    Text("Le scan part à ces adresses, dans la fenêtre Mail de l'iPhone : rien ne part sans un appui sur Envoyer. Elles restent sur l'iPhone.")
                }
                Section {
                    TextField(IrisReglages.objetParDefaut, text: $reglages.objet)
                        .textInputAutocapitalization(.sentences)
                } header: {
                    Text("Objet du mail")
                } footer: {
                    Text(verbatim: "Suivi du nom du scan, par exemple « \(reglages.objetEffectif) · Ticket 2026-10-16 ».")
                }
                Section {
                    Toggle("Garder le scan dans Photos", isOn: $reglages.garderDansPhotos)
                } footer: {
                    if reglages.garderDansPhotos && IrisPhotosSysteme.refuse {
                        Text("Iris n'a pas accès à Photos : à autoriser dans Réglages › Apps › Égide › Photos.")
                    } else {
                        Text("Les pages sont ajoutées à Photos, sans le lieu de la prise de vue. Sinon, le scan ne reste que dans Iris.")
                    }
                }
                sectionMac
            }
            .egideRow()
        }
        .egideList()
        .foregroundStyle(EgideTheme.encre)
        .navigationTitle("Réglages")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: reglages) { reglages.enregistrer() }
        .fileImporter(isPresented: $choixDossier, allowedContentTypes: [.folder]) { resultat in
            guard case .success(let url) = resultat else { return }
            do {
                try copieMac.choisir(url)
                compteRendu = nil
            } catch {
                compteRendu = "Dossier inaccessible : \(error.localizedDescription)"
            }
            relire()
        }
    }

    private var sectionMac: some View {
        Section {
            if let dossierMac {
                LabeledContent("Dossier", value: dossierMac)
                Button {
                    copieEnCours = true
                    Task {
                        let nombre = await copieMac.copier(IrisScans().liste(), saufDejaLa: true)
                        copieEnCours = false
                        compteRendu = nombre == 0 ? "Rien à copier : les scans y sont déjà."
                            : nombre == 1 ? "1 scan copié." : "\(nombre) scans copiés."
                        relire()
                    }
                } label: {
                    HStack {
                        Label("Copier les scans déjà faits", systemImage: "doc.on.doc")
                        Spacer()
                        if copieEnCours { ProgressView() }
                    }
                }
                .disabled(copieEnCours)
                Button("Changer de dossier") { choixDossier = true }
                Button("Arrêter la copie", role: .destructive) {
                    copieMac.arreter()
                    compteRendu = nil
                    relire()
                }
            } else {
                Button("Choisir le dossier", systemImage: "folder.badge.plus") { choixDossier = true }
            }
        } header: {
            Text("Copie sur le Mac")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Chaque nouveau scan est copié dans ce dossier, par exemple iCloud Drive › Iris, rangé dans Tickets, Factures ou Documents. Sur le Mac, le Finder l'affiche et Spotlight cherche dans son texte. Un scan supprimé ici reste dans le dossier.")
                if let erreurMac {
                    Text(erreurMac).foregroundStyle(.red)
                } else if let compteRendu {
                    Text(compteRendu)
                }
            }
        }
    }

    private func relire() {
        dossierMac = copieMac.nomDossier
        erreurMac = copieMac.erreur
    }

    @ViewBuilder
    private func champAdresse(_ index: Int) -> some View {
        let liaison = Binding<String>(
            get: { index < reglages.destinataires.count ? reglages.destinataires[index] : "" },
            set: { valeur in
                while reglages.destinataires.count <= index { reglages.destinataires.append("") }
                reglages.destinataires[index] = valeur
            })
        let texte = liaison.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        HStack {
            TextField("Adresse \(index + 1)", text: liaison)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !texte.isEmpty && !IrisReglages.adresseValide(texte) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    .accessibilityLabel("Adresse incomplète")
            }
        }
    }
}

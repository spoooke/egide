import EgideUI
import SwiftData
import SwiftUI

/// Réglages de Money : plafond de la semaine et plafond mensuel de chaque poste (en euros).
struct ReglagesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Poste.ordre) private var postes: [Poste]
    @AppStorage("money.plafondHebdoCentimes") private var plafondHebdo = 135_00
    @State private var importEnCours = false
    @State private var messageImport: String?
    @State private var choixCSV = false
    @State private var messageCSV: String?
    @State private var nomCSV = FichierSecours.nom
    @State private var sauvegarde: PactoleBackupDocument?
    @State private var choixRestauration = false
    @State private var messageSauvegarde: String?

    var body: some View {
        Form {
            Group {
                Section {
                    LabeledContent("Plafond de la semaine") {
                        ChampEuros(placeholder: "135", valeur: Binding(get: { euros($plafondHebdo).wrappedValue },
                                                                      set: { euros($plafondHebdo).wrappedValue = $0 ?? 0 }))
                    }
                } footer: {
                    Text("Les postes hors plafond (Imprévu) ne comptent pas dans la semaine.")
                }

                Section {
                    ForEach(postes) { poste in
                        @Bindable var poste = poste
                        VStack(alignment: .leading) {
                            LabeledContent {
                                ChampEuros(placeholder: "aucun", valeur: plafondMensuel(poste))
                            } label: {
                                Label(poste.nom, systemImage: poste.symbole)
                            }
                            Toggle("Hors plafond de la semaine", isOn: $poste.horsPlafondHebdo)
                                .font(.footnote)
                                .onChange(of: poste.horsPlafondHebdo) { poste.modifiedAt = .now; try? context.save() }
                        }
                    }
                } header: {
                    Text("Plafonds mensuels par poste")
                } footer: {
                    Text("Champ vide : pas de plafond pour ce poste.")
                }

                Section {
                    NavigationLink { FraisFixesView() } label: { Label("Frais fixes et abonnements", systemImage: "repeat") }
                    NavigationLink { RevenusView() } label: { Label("Revenus", systemImage: "banknote") }
                    NavigationLink { VirementsView() } label: { Label("Virements reçus", systemImage: "arrow.down.left.circle") }
                    NavigationLink { RelevesView() } label: { Label("Relevés ajoutés", systemImage: "building.columns") }
                } header: {
                    Text("Budget du mois")
                }

                Section {
                    Toggle("Bilan de la semaine le dimanche à 20 h", isOn: notification(PactoleNotifications.cleBilan))
                    Toggle("Alerte à 80 % du plafond d'un poste", isOn: notification(PactoleNotifications.cleAlertes))
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Propres à cet appareil : active-les sur un seul (l'iPhone, par exemple) pour ne pas les recevoir deux fois.")
                }

                Section {
                    NavigationLink { SyncView() } label: {
                        #if os(macOS)
                        Label("Synchro avec l'iPhone", systemImage: "arrow.triangle.2.circlepath")
                        #else
                        Label("Synchro avec le Mac", systemImage: "arrow.triangle.2.circlepath")
                        #endif
                    }
                }

                Section {
                    NavigationLink { ReglesView() } label: { Label("Classement des commerçants", systemImage: "list.bullet.rectangle") }
                    #if os(iOS)
                    if let nomCSV {
                        LabeledContent("Fichier de secours", value: nomCSV)
                        Button("Lire maintenant", systemImage: "arrow.clockwise") { lireCSV() }
                        Button("Ne plus lire ce fichier", role: .destructive) { FichierSecours.oublier(); self.nomCSV = nil }
                    } else {
                        Button("Choisir transactions.csv", systemImage: "doc.badge.plus") { choixCSV = true }
                    }
                    #endif
                } header: {
                    Text("Apple Pay")
                } footer: {
                    #if os(iOS)
                    Text(messageCSV ?? "Le fichier transactions.csv (iCloud Drive › Desktop › Perso › Budget), écrit par l'automatisation Raccourcis, est relu à chaque ouverture de Pactole : les paiements qui n'auraient pas été enregistrés sont ajoutés, sans doublon.")
                    #else
                    Text("Les paiements Apple Pay arrivent par l'iPhone (synchro).")
                    #endif
                }

                Section {
                    Button("Exporter une sauvegarde", systemImage: "square.and.arrow.up") { exporter() }
                    Button("Restaurer une sauvegarde", systemImage: "clock.arrow.circlepath") { choixRestauration = true }
                } header: {
                    Text("Sauvegarde")
                } footer: {
                    Text(messageSauvegarde ?? "Un fichier JSON avec les dépenses, postes et plafonds, règles de classement, frais fixes et revenus. La restauration n'efface rien : elle ajoute ce qui manque et ne remplace que par plus récent.")
                }

                Section {
                    Button("Importer un fichier du Suivi hebdo", systemImage: "square.and.arrow.down") { importEnCours = true }
                } header: {
                    Text("Reprise du Suivi hebdo")
                } footer: {
                    Text(messageImport ?? "Fichier JSON exporté de l'artefact « Suivi hebdo ». Les dépenses déjà importées ne sont jamais ajoutées deux fois ; les plafonds sont repris.")
                }
            }
            .egideRow()
        }
        .egideList()
        .formStyle(.grouped)
        .egideTitre("Réglages")
        .fileImporter(isPresented: $importEnCours, allowedContentTypes: [.json]) { resultat in
            importer(resultat)
        }
        .background {
            // Second sélecteur sur une vue distincte : SwiftUI n'en gère qu'un par vue.
            Color.clear.fileImporter(isPresented: $choixCSV, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { resultat in
                do {
                    try FichierSecours.choisir(try resultat.get())
                    nomCSV = FichierSecours.nom
                    lireCSV()
                } catch {
                    messageCSV = "Fichier inaccessible : \(error.localizedDescription)"
                }
            }
        }
        .background {
            Color.clear.fileImporter(isPresented: $choixRestauration, allowedContentTypes: [.json]) { restaurer($0) }
        }
        .fileExporter(isPresented: Binding(get: { sauvegarde != nil }, set: { if !$0 { sauvegarde = nil } }),
                      document: sauvegarde, contentType: .json, defaultFilename: PactoleBackup.nomFichier()) { resultat in
            switch resultat {
            case .success(let url): messageSauvegarde = "Sauvegarde enregistrée : \(url.lastPathComponent)."
            case .failure(let error): messageSauvegarde = "Échec de l'export : \(error.localizedDescription)"
            }
        }
    }

    private func exporter() {
        do {
            sauvegarde = PactoleBackupDocument(data: try PactoleBackup.make(from: context).encoded())
        } catch {
            messageSauvegarde = "Échec de la sauvegarde : \(error.localizedDescription)"
        }
    }

    private func restaurer(_ resultat: Result<URL, Error>) {
        do {
            let url = try resultat.get()
            let acces = url.startAccessingSecurityScopedResource()
            defer { if acces { url.stopAccessingSecurityScopedResource() } }
            let donnees = try Data(contentsOf: url)
            guard let fichier = try? PactoleBackup.decode(donnees) else {
                messageSauvegarde = "Fichier illisible : ce n'est pas une sauvegarde de Pactole."
                return
            }
            messageSauvegarde = "Restauration : \(try fichier.restaurer(dans: context))."
        } catch {
            messageSauvegarde = "Restauration impossible : \(error.localizedDescription)"
        }
    }

    private func lireCSV() {
        do {
            guard let bilan = try FichierSecours.lire(dans: context) else { return }
            var texte = "\(bilan.ajoutees) paiement(s) ajouté(s), \(bilan.doublons) déjà enregistré(s)"
            if bilan.illisibles > 0 { texte += ", \(bilan.illisibles) ligne(s) illisible(s)" }
            messageCSV = texte + "."
        } catch {
            messageCSV = "Lecture impossible : \(error.localizedDescription)"
        }
    }

    private func importer(_ resultat: Result<URL, Error>) {
        do {
            let url = try resultat.get()
            let acces = url.startAccessingSecurityScopedResource()
            defer { if acces { url.stopAccessingSecurityScopedResource() } }
            let bilan = try SuiviHebdo.decode(try Data(contentsOf: url)).importer(dans: context)
            var texte = "\(bilan.ajoutees) dépense(s) ajoutée(s)"
            if bilan.dejaPresentes > 0 { texte += ", \(bilan.dejaPresentes) déjà présente(s)" }
            if bilan.ignorees > 0 { texte += ", \(bilan.ignorees) illisible(s)" }
            messageImport = texte + ". Plafonds repris."
        } catch {
            messageImport = "Fichier illisible : ce n'est pas un export du Suivi hebdo."
        }
    }

    /// Interrupteur de notification : demande l'autorisation à l'activation, reprogramme le bilan.
    private func notification(_ cle: String) -> Binding<Bool> {
        Binding(get: { UserDefaults.standard.bool(forKey: cle) }, set: { actif in
            UserDefaults.standard.set(actif, forKey: cle)
            Task {
                if actif, !(await PactoleNotifications.demanderAutorisation()) { UserDefaults.standard.set(false, forKey: cle) }
                PactoleNotifications.planifierBilan(context)
            }
        })
    }

    private func euros(_ centimes: Binding<Int>) -> Binding<Int> {
        Binding(get: { centimes.wrappedValue / 100 }, set: {
            centimes.wrappedValue = max(0, $0) * 100
            PactoleReglages.plafondHebdoModifie = .now // la valeur la plus récente gagne à la synchro
            PactoleSync.shared.scheduleSync()
        })
    }

    private func plafondMensuel(_ poste: Poste) -> Binding<Int?> {
        Binding(get: { poste.plafondMensuelCentimes.map { $0 / 100 } },
                set: {
                    poste.plafondMensuelCentimes = $0.map { max(0, $0) * 100 }
                    poste.modifiedAt = .now
                    try? context.save()
                })
    }
}

/// Montant en euros entiers, aligné à droite, suivi de « € » sur la même ligne.
private struct ChampEuros: View {
    let placeholder: String
    @Binding var valeur: Int?

    var body: some View {
        HStack(spacing: 4) {
            TextField("Montant", value: $valeur, format: .number, prompt: Text(placeholder))
                .labelsHidden() // sur Mac, le titre s'afficherait à gauche du champ
                .clavierMontant(entier: true)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 90)
            Text("€").foregroundStyle(.secondary)
        }
    }
}

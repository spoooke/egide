import EgideUI
import SwiftData
import SwiftUI

/// Solde du compte saisi à la main, et ce qui peut être dépensé jusqu'à la prochaine paie sans finir à découvert.
struct TresorerieView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Depense.date, order: .reverse) private var depenses: [Depense]
    @Query private var frais: [FraisFixe]
    @Query private var virements: [Virement]
    @Query(sort: \Revenu.mois, order: .reverse) private var revenus: [Revenu]
    @AppStorage("money.soldeCentimes") private var soldeCentimes = 0
    /// Date du solde saisi, en secondes Unix (0 : jamais saisi).
    @AppStorage("money.soldeDate") private var soldeDate = 0.0
    /// Dernier jour possible de la paie (elle tombe entre le 1er et le 6).
    @AppStorage("money.jourPaie") private var jourPaie = 6
    /// Salaire marqué reçu, en secondes Unix (0 : pas marqué).
    @AppStorage("money.paieRecue") private var paieRecue = 0.0
    /// Plus utilisé (le dernier salaire reçu sert au calcul) ; gardé pour le format du fichier de synchro.
    @AppStorage("money.salaireAttenduCentimes") private var salaireAttendu = 0
    @AppStorage("money.margeCentimes") private var marge = 100_00
    @AppStorage("money.plafondHebdoCentimes") private var plafondHebdo = 135_00
    @State private var saisie = ""
    @State private var decouvert = false
    @State private var texteMarge = ""
    @State private var salaireRecu = ""

    private var valeurs: ReglagesTresorerie {
        ReglagesTresorerie(soldeCentimes: soldeCentimes, soldeDate: soldeDate, jourPaie: jourPaie,
                           salaireAttenduCentimes: salaireAttendu, margeCentimes: marge, paieRecue: paieRecue)
    }

    private var dernierSalaire: Int {
        revenus.first { Rapprochement.estLibelleSalaire($0.libelle) }?.montantCentimes ?? 0
    }
    /// Valeur sûre : le dernier salaire réellement reçu (revenus), jamais une estimation.
    private var salaire: Int { dernierSalaire }

    var body: some View {
        TimelineView(.everyMinute) { contexte in
            List {
                Group {
                    Section {
                        TextField("Solde affiché par la banque", text: $saisie).clavierMontant()
                        Toggle("À découvert", isOn: $decouvert)
                        Button("Enregistrer le solde", systemImage: "checkmark") {
                            guard let centimes = Montant.centimes(depuis: saisie) else { return }
                            soldeCentimes = decouvert ? -centimes : centimes
                            soldeDate = Date.now.timeIntervalSince1970
                            saisie = ""
                        }
                        .disabled(Montant.centimes(depuis: saisie) == nil)
                    } header: {
                        Text("Solde du compte")
                    } footer: {
                        if soldeDate > 0 {
                            let date = Date(timeIntervalSince1970: soldeDate)
                            Text("Saisi : \(Montant.texte(soldeCentimes)) le \(date.formatted(Date.FormatStyle(locale: Locale(identifier: "fr_FR")).day().month(.wide).hour().minute())). Les dépenses saisies ensuite (Apple Pay en cours compris) sont déduites.")
                        } else {
                            Text("Saisis le solde quelques jours avant la paie ; les dépenses saisies ensuite seront déduites.")
                        }
                    }

                    if soldeDate > 0 {
                        resultat(Tresorerie.calculer(solde: soldeCentimes, datePoint: Date(timeIntervalSince1970: soldeDate),
                                                     jourPaie: jourPaie, salaire: salaire, marge: marge,
                                                     paieRecue: paieRecue > 0 ? Date(timeIntervalSince1970: paieRecue) : nil,
                                                     depenses: depenses, frais: frais, virements: virements, maintenant: contexte.date))
                    }

                    Section("Réglages") {
                        Stepper("Paie au plus tard le \(jourPaie)", value: $jourPaie, in: 1...31)
                        LabeledContent("Salaire reçu", value: salaire > 0 ? Montant.texte(salaire) : "Aucun")
                        LabeledContent("Marge à garder") {
                            TextField(Montant.texte(marge), text: $texteMarge).clavierMontant()
                                .multilineTextAlignment(.trailing)
                                .onChange(of: texteMarge) { _, texte in if let m = Montant.centimes(depuis: texte) { marge = m } }
                        }
                    }
                }
                .egideRow()
            }
            .egideList()
        }
        .egideTitre("Solde et paie")
        // Changement daté, pour que la synchro le fasse gagner sur l'autre appareil (une valeur reçue de la synchro
        // est redatée ici sans conséquence : l'autre appareil a déjà la même).
        .onChange(of: valeurs) {
            PactoleReglages.tresorerieModifie = .now
            PactoleSync.shared.scheduleSync()
        }
    }

    /// Salaire reçu : ajouté aux revenus du mois au montant exact (le relevé le reconnaîtra comme déjà saisi),
    /// et compté dès maintenant dans le solde.
    private func enregistrerSalaire() {
        guard let centimes = Montant.centimes(depuis: salaireRecu) else { return }
        let mois = Revenu.cle(.now)
        if !revenus.contains(where: { $0.mois == mois && $0.montantCentimes == centimes }) {
            let libelle = revenus.first { Rapprochement.estLibelleSalaire($0.libelle) }?.libelle ?? "Salaire"
            context.insert(Revenu(mois: mois, libelle: libelle, montantCentimes: centimes))
            try? context.save()
        }
        salaireAttendu = 0
        paieRecue = Date.now.timeIntervalSince1970
        salaireRecu = ""
    }

    /// La paie attendue tombe dans les six jours : le bouton « Salaire reçu » la compte dès son arrivée.
    private func paieAttendue(_ t: Tresorerie) -> Bool { t.joursAvantPaie <= 6 }

    @ViewBuilder
    private func resultat(_ t: Tresorerie) -> some View {
        let format = Date.FormatStyle(locale: Locale(identifier: "fr_FR")).day().month(.wide)
        Section {
            LabeledContent("Solde estimé aujourd'hui") {
                Text(Montant.texte(t.soldeAujourdhui)).bold().foregroundStyle(t.soldeAujourdhui < 0 ? .red : .primary)
            }
            LabeledContent("Avant la paie, sans autre dépense") {
                Text(Montant.texte(t.soldeAvantPaie)).foregroundStyle(t.soldeAvantPaie < 0 ? .red : .secondary)
            }
            if t.aDepenserAvantPaie > 0 {
                LabeledContent("Encore possible d'ici là", value: Montant.texte(t.aDepenserAvantPaie))
                LabeledContent("Soit par jour", value: Montant.texte(Tresorerie.parJour(t.aDepenserAvantPaie, jours: t.joursAvantPaie)))
            } else {
                Text("Plus de marge d'ici la paie : le strict minimum.").foregroundStyle(.orange)
            }
            if paieAttendue(t) {
                TextField("Montant exact du salaire reçu", text: $salaireRecu).clavierMontant()
                Button("Salaire reçu", systemImage: "eurosign.circle") { enregistrerSalaire() }
                    .disabled(Montant.centimes(depuis: salaireRecu) == nil)
            }
        } header: {
            Text("Jusqu'à la paie, au plus tard le \(t.prochainePaie.formatted(format)) (\(t.joursAvantPaie) j)")
        }

        let hebdo = Tresorerie.parSemaine(t.aDepenserCycleSuivant, jours: t.joursCycleSuivant)
        Section {
            LabeledContent("À dépenser sur le cycle") {
                Text(Montant.texte(t.aDepenserCycleSuivant)).bold().foregroundStyle(t.aDepenserCycleSuivant < 0 ? .red : .green)
            }
            LabeledContent("Soit par semaine", value: Montant.texte(hebdo))
            LabeledContent("Soit par jour", value: Montant.texte(Tresorerie.parJour(t.aDepenserCycleSuivant, jours: t.joursCycleSuivant)))
            if hebdo > 0 && hebdo != plafondHebdo {
                Button("Utiliser \(Montant.texte(hebdo)) comme plafond hebdo", systemImage: "gauge.with.needle") { PactoleReglages.plafondHebdoCentimes = hebdo; PactoleSync.shared.scheduleSync() }
            }
        } header: {
            Text("Du \(t.prochainePaie.formatted(format)) au \(t.paieSuivante.formatted(format))")
        } footer: {
            Text("Dernier salaire reçu (\(Montant.texte(salaire))) moins les frais fixes du cycle et \(Montant.texte(marge)) de marge, en partant du solde avant la paie. Le plafond hebdo actuel est de \(Montant.texte(plafondHebdo)) (hors Imprévu, alors que ce calcul compte toutes les dépenses).")
        }
    }
}

import Foundation

/// Lit les capteurs du Mac. Les clés SMC sont recensées une seule fois, à l'ouverture.
@MainActor
final class Lecteur {
    private let smc = SMC()
    private let hid = CapteursHID()
    private var charge = ChargeProcesseur()
    private let accelerateur = Accelerateur()
    /// Toutes les clés de température (T…) lisibles comme un nombre.
    private let temperatures: [SMC.Cle]
    /// Celles du résumé : processeur, puce graphique, batterie.
    private let resume: [SMC.Cle]
    private let ventilateurs: [(actuel: SMC.Cle, mini: Double, maxi: Double)]
    /// Secondes entre deux lectures du disque : il se remplit lentement, et la question coûte plus que les autres.
    static let intervalleDisque = 60.0
    private var disque: (valeur: Disque?, date: Date)?

    init() {
        guard let smc else {
            temperatures = []
            resume = []
            ventilateurs = []
            return
        }
        temperatures = smc.toutesLesCles().filter { $0.hasPrefix("T") }.compactMap(smc.cle).filter { smc.nombre($0) != nil }
        resume = temperatures.filter { Famille.smc($0.nom) != .autreSMC }
        ventilateurs = (0..<Int(smc.nombre("FNum") ?? 0)).compactMap { i in
            smc.cle("F\(i)Ac").map { ($0, smc.nombre("F\(i)Mn") ?? 0, smc.nombre("F\(i)Mx") ?? 0) }
        }
    }

    private func lire(_ cles: [SMC.Cle]) -> [String: Double] {
        guard let smc else { return [:] }
        return Dictionary(uniqueKeysWithValues: cles.compactMap { cle in smc.nombre(cle).map { (cle.nom, $0) } })
    }

    /// `carteGraphique` : relever aussi la puce graphique.
    func releve(carteGraphique: Bool = false) -> Releve {
        let tours = ventilateurs.compactMap { ventilateur in
            smc?.nombre(ventilateur.actuel).map { Ventilateur(toursParMinute: $0, mini: ventilateur.mini, maxi: ventilateur.maxi) }
        }
        var releve = Releve(date: .now, smc: lire(resume), ssd: hid.lire(Famille.nomSSD), ventilateurs: tours, charge: charge.lire())
        releve.memoire = Ressources.memoire()
        if carteGraphique { releve.carteGraphique = accelerateur.lire() }
        if disque.map({ abs(releve.date.timeIntervalSince($0.date)) >= Self.intervalleDisque }) ?? true {
            disque = (Ressources.disque(), releve.date)
        }
        releve.disque = disque?.valeur
        return releve
    }

    /// Tous les capteurs plausibles, pour la liste détaillée.
    func sondes() -> [Sonde] {
        let valeurs = lire(temperatures)
        let smc = temperatures.compactMap { cle in
            valeurs[cle.nom].map { Sonde(id: "smc:\(cle.nom)", nom: cle.nom, famille: .smc(cle.nom), degres: $0) }
        }
        var rangs: [String: Int] = [:]
        let hid = hid.tous().map { capteur in
            rangs[capteur.nom, default: 0] += 1
            return Sonde(id: "hid:\(capteur.nom)#\(rangs[capteur.nom]!)", nom: capteur.nom, famille: .hid(capteur.nom), degres: capteur.degres)
        }
        return (smc + hid).filter { Releve.plausible($0.degres) }
    }
}

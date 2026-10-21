import Foundation

/// Mode démo : lancer Égide avec `-egide.demo YES` remplace les données réelles par des données inventées
/// (budget, idées, machines, audits, scans), pour faire des captures sans rien montrer de personnel.
/// Rien n'est lu ni écrit dans les vraies bases pendant ce mode.
public enum EgideDemo {
    public static var actif: Bool { UserDefaults.standard.bool(forKey: "egide.demo") }
}

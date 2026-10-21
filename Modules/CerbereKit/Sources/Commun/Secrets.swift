import Foundation

/// Secrets écrits en dur (clés, jetons, mots de passe) : relevés par la couche 1, et masqués avant tout envoi
/// à la lecture par IA. Le masque remplace le secret sur place : les numéros de ligne ne bougent pas.
enum Secrets {
    static let masque = "«secret masqué»"

    private struct Motif: @unchecked Sendable {
        let nom: String
        /// Le premier groupe est le secret à masquer.
        let motif: NSRegularExpression
        var generique = false

        init(_ nom: String, _ motif: String, casse: Bool = true, generique: Bool = false) {
            self.nom = nom
            self.motif = try! NSRegularExpression(pattern: motif, options: casse ? [] : [.caseInsensitive])
            self.generique = generique
        }
    }

    private static let motifs: [Motif] = [
        Motif("clé AWS", #"\b((?:AKIA|ASIA)[0-9A-Z]{16})\b"#),
        Motif("jeton GitHub", #"\b(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})"#),
        Motif("clé d'API", #"\b(sk-(?:ant-|proj-|or-)?[A-Za-z0-9_-]{24,})"#),
        Motif("jeton Slack", #"\b(xox[abeprs]-[A-Za-z0-9-]{10,})"#),
        Motif("clé Google", #"\b(AIza[0-9A-Za-z_-]{35})"#),
        Motif("clé Stripe", #"\b((?:sk|rk)_(?:live|test)_[0-9A-Za-z]{16,})"#),
        Motif("jeton npm", #"\b(npm_[A-Za-z0-9]{36})\b"#),
        Motif("jeton PyPI", #"\b(pypi-AgEIcHlwaS5vcmc[A-Za-z0-9_-]{20,})"#),
        Motif("jeton JWT", #"\b(eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})"#),
        Motif("identifiants dans une adresse", #"[a-z][a-z0-9+.-]*://[^\s/:@'"]+:([^\s/@'"]{3,})@"#, casse: false),
        Motif("jeton d'accès", #"\bBearer\s+([A-Za-z0-9._~+/-]{20,}=*)"#),
        Motif("jeton de webhook", #"(?:discord(?:app)?\.com/api/webhooks/\d+/|hooks\.slack\.com/services/|api\.telegram\.org/bot)([A-Za-z0-9_:/-]{16,})"#, casse: false),
        Motif("mot de passe ou jeton",
              #"\b[a-z0-9_.-]*(?:passw(?:or)?d|pwd|mot_?de_?passe|mdp|secret|token|jeton|api[_-]?key|apikey|access[_-]?key|private[_-]?key|auth[_-]?key)[a-z0-9_]*["']?\s*[:=]\s*["']([^"'\s]{8,})["']"#,
              casse: false, generique: true),
    ]
    private static let debutCle = try! NSRegularExpression(pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY( BLOCK)?-----"#)
    private static let finCle = try! NSRegularExpression(pattern: #"-----END [A-Z ]*PRIVATE KEY( BLOCK)?-----"#)

    /// Valeur d'exemple ou valeur lue ailleurs : pas un secret.
    private static func factice(_ valeur: String) -> Bool {
        let v = valeur.lowercased()
        if ["example", "exemple", "your", "votre", "xxxx", "changeme", "change_me", "placeholder", "dummy", "todo", "<", "${", "{{", "%(", "process.env", "os.environ", "getenv"].contains(where: v.contains) { return true }
        return Set(v).count < 5
    }

    private static func trouve(_ motif: NSRegularExpression, _ s: String) -> Bool {
        motif.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// Secrets d'une ligne : nom du motif et emplacement du secret.
    private static func occurrences(_ ligne: String) -> [(nom: String, plage: NSRange)] {
        // Aucun motif ne tient en moins de 12 caractères ; une ligne géante est traitée comme les autres.
        guard ligne.utf16.count >= 12 else { return [] }
        var trouves: [(String, NSRange)] = []
        let entier = NSRange(location: 0, length: (ligne as NSString).length)
        for m in motifs {
            m.motif.enumerateMatches(in: ligne, range: entier) { resultat, _, _ in
                guard let plage = resultat?.range(at: 1), plage.location != NSNotFound else { return }
                if m.generique, factice((ligne as NSString).substring(with: plage)) { return }
                if !trouves.contains(where: { NSIntersectionRange($0.1, plage).length > 0 }) { trouves.append((m.nom, plage)) }
            }
        }
        return trouves
    }

    /// Lignes avec les secrets remplacés par le masque, et leur nombre. Une clé privée (bloc PEM) est masquée en entier.
    static func masquer(_ lignes: [String]) -> (lignes: [String], nombre: Int) {
        var sortie: [String] = [], nombre = 0, dansUneCle = false
        sortie.reserveCapacity(lignes.count)
        for ligne in lignes {
            if dansUneCle {
                if trouve(finCle, ligne) { dansUneCle = false; sortie.append(ligne) } else { sortie.append(masque) }
                continue
            }
            if trouve(debutCle, ligne) {
                nombre += 1
                // Clé sur une seule ligne (dans une chaîne) : toute la ligne est masquée.
                if trouve(finCle, ligne) { sortie.append(masque) } else { dansUneCle = true; sortie.append(ligne) }
                continue
            }
            let trouves = occurrences(ligne).sorted { $0.plage.location > $1.plage.location }
            guard !trouves.isEmpty else { sortie.append(ligne); continue }
            let texte = NSMutableString(string: ligne)
            for (_, plage) in trouves { texte.replaceCharacters(in: plage, with: masque) }
            nombre += trouves.count
            sortie.append(texte as String)
        }
        return (sortie, nombre)
    }

    static func masquer(_ texte: String) -> String {
        masquer(texte.components(separatedBy: "\n")).lignes.joined(separator: "\n")
    }

    /// Constats de la couche 1 : l'extrait est déjà masqué, le secret ne passe pas dans le rapport.
    static func constats(_ f: Fichier) -> [Constat] {
        guard !f.estGenere else { return [] }
        var constats: [Constat] = [], total = 0
        for (i, ligne) in f.lignes.enumerated() {
            let estCle = trouve(debutCle, ligne)
            guard let nom = estCle ? "clé privée" : occurrences(ligne).first?.nom else { continue }
            total += 1
            guard constats.count < Moteur.occurrencesMax else { continue }
            constats.append(Constat(
                id: "", gravite: .faible, statut: .suspect, categorie: .secrets, titre: "Secret écrit en dur (\(nom))",
                fichier: f.chemin, lignes: [i + 1, i + 1], extrait: String(masquer([ligne]).lignes[0].trimmingCharacters(in: .whitespaces).prefix(240)),
                explication: "Une clé, un jeton ou un mot de passe est écrit dans le code. Sans danger direct pour qui installe, mais signe d'un projet peu soigné ; masqué avant tout envoi à l'IA.",
                origine: .regle, regle: "sec.en-dur"))
        }
        if total > constats.count, var dernier = constats.popLast() {
            dernier.explication += " (+\(total - constats.count - 1) autres occurrences dans ce fichier.)"
            constats.append(dernier)
        }
        return constats
    }
}

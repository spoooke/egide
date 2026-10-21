import Foundation

/// Décompression « deflate » (RFC 1951) en Swift, pour les flux des PDF : la bibliothèque de compression d'Apple
/// n'existe pas sur Windows. Lecture bornée : au-delà de `max` octets produits, ou sur un flux abîmé, rien n'est rendu.
struct Degonfleur {
    private struct Huffman {
        var nombres = [Int](repeating: 0, count: 16)
        var symboles: [Int]

        /// Table canonique à partir des longueurs de code ; nil si les longueurs sont incohérentes.
        init?(_ longueurs: ArraySlice<Int>) {
            symboles = [Int](repeating: 0, count: longueurs.count)
            for l in longueurs { nombres[l] += 1 }
            var reste = 1
            for l in 1..<16 {
                reste = reste << 1 - nombres[l]
                if reste < 0 { return nil }
            }
            var debuts = [Int](repeating: 0, count: 16)
            for l in 1..<15 { debuts[l + 1] = debuts[l] + nombres[l] }
            for (s, l) in longueurs.enumerated() where l != 0 {
                symboles[debuts[l]] = s
                debuts[l] += 1
            }
        }
    }

    private struct Erreur: Error {}

    private static let baseLongueur = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let extraLongueur = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let baseDistance = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097,
                                       6145, 8193, 12289, 16385, 24577]
    private static let extraDistance = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let ordre = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private let entree: [UInt8]
    private let max: Int
    private var position = 0
    private var tampon = 0
    private var restants = 0
    private var sortie: [UInt8] = []

    private init(_ entree: [UInt8], max: Int) {
        self.entree = entree
        self.max = max
    }

    static func degonfler(_ flux: Data, max: Int) -> Data? {
        var d = Degonfleur([UInt8](flux), max: max)
        do {
            var dernier = false
            while !dernier {
                dernier = try d.bits(1) == 1
                switch try d.bits(2) {
                case 0: try d.stocke()
                case 1: try d.codes(Self.fixes.0, Self.fixes.1)
                case 2: try d.dynamique()
                default: return nil
                }
            }
        } catch { return nil }
        return Data(d.sortie)
    }

    private mutating func bits(_ n: Int) throws -> Int {
        while restants < n {
            guard position < entree.count else { throw Erreur() }
            tampon |= Int(entree[position]) << restants
            position += 1
            restants += 8
        }
        let v = tampon & ((1 << n) - 1)
        tampon >>= n
        restants -= n
        return v
    }

    private mutating func ajouter(_ octet: UInt8) throws {
        guard sortie.count < max else { throw Erreur() }
        sortie.append(octet)
    }

    private mutating func stocke() throws {
        tampon = 0
        restants = 0
        guard position + 4 <= entree.count else { throw Erreur() }
        let longueur = Int(entree[position]) | Int(entree[position + 1]) << 8
        let complement = Int(entree[position + 2]) | Int(entree[position + 3]) << 8
        position += 4
        guard longueur == ~complement & 0xFFFF, position + longueur <= entree.count else { throw Erreur() }
        for octet in entree[position..<position + longueur] { try ajouter(octet) }
        position += longueur
    }

    private mutating func decoder(_ h: Huffman) throws -> Int {
        var code = 0, premier = 0, index = 0
        for longueur in 1..<16 {
            code |= try bits(1)
            let nombre = h.nombres[longueur]
            if code - nombre < premier { return h.symboles[index + code - premier] }
            index += nombre
            premier = (premier + nombre) << 1
            code <<= 1
        }
        throw Erreur()
    }

    private mutating func codes(_ litteraux: Huffman, _ distances: Huffman) throws {
        while true {
            let symbole = try decoder(litteraux)
            if symbole < 256 { try ajouter(UInt8(symbole)); continue }
            if symbole == 256 { return }
            let i = symbole - 257
            guard i < Self.baseLongueur.count else { throw Erreur() }
            let longueur = Self.baseLongueur[i] + (try bits(Self.extraLongueur[i]))
            let j = try decoder(distances)
            guard j < Self.baseDistance.count else { throw Erreur() }
            let distance = Self.baseDistance[j] + (try bits(Self.extraDistance[j]))
            guard distance <= sortie.count else { throw Erreur() }
            for _ in 0..<longueur { try ajouter(sortie[sortie.count - distance]) }
        }
    }

    private static let fixes: (Huffman, Huffman) = {
        var l = [Int](repeating: 8, count: 288)
        for i in 144..<256 { l[i] = 9 }
        for i in 256..<280 { l[i] = 7 }
        return (Huffman(l[...])!, Huffman([Int](repeating: 5, count: 30)[...])!)
    }()

    private mutating func dynamique() throws {
        let nLitteraux = try bits(5) + 257, nDistances = try bits(5) + 1, nCodes = try bits(4) + 4
        guard nLitteraux <= 286, nDistances <= 30 else { throw Erreur() }
        var l = [Int](repeating: 0, count: 19)
        for i in 0..<nCodes { l[Self.ordre[i]] = try bits(3) }
        guard let codesLongueurs = Huffman(l[...]) else { throw Erreur() }
        var longueurs: [Int] = []
        while longueurs.count < nLitteraux + nDistances {
            let s = try decoder(codesLongueurs)
            switch s {
            case 0..<16: longueurs.append(s)
            case 16:
                guard let precedent = longueurs.last else { throw Erreur() }
                longueurs += [Int](repeating: precedent, count: 3 + (try bits(2)))
            case 17: longueurs += [Int](repeating: 0, count: 3 + (try bits(3)))
            default: longueurs += [Int](repeating: 0, count: 11 + (try bits(7)))
            }
        }
        guard longueurs.count == nLitteraux + nDistances, longueurs[256] != 0,
              let litteraux = Huffman(longueurs[..<nLitteraux]), let distances = Huffman(longueurs[nLitteraux...]) else { throw Erreur() }
        try codes(litteraux, distances)
    }
}

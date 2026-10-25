// Copie l'icône de chaque outil (celle de son app) dans Égide, pour l'écran d'accueil : Icone-<module>, 512 px.
// Sources : les dépôts voisins (Argos, Hermès, Muse) et les icônes de Pactole (PactoleMac), d'Héphaïstos (HephaistosMac), de Cerbère (CerbereMac), d'Iris (IrisKit) et de Mnémosyne (MnemosyneKit).
// Written to both catalogues: Égide on the iPhone and Égide on the Mac.
// swift scripts/make-module-icons.swift
import AppKit

let soft = URL(fileURLWithPath: "..")
let sources: [(module: String, chemin: String)] = [
    ("argos", "Argos/argos/design/icon.svg"),
    ("hermes", "Hermes/iOSApp/Assets.xcassets/AppIcon.appiconset/icon-1024.png"),
    ("muse", "Muse/Muse/Resources/Assets.xcassets/AppIcon.appiconset/icon-ios-1024.png"),
    ("money", "EGIDE/PactoleMac/Resources/money-icon.svg"),
    ("hephaistos", "EGIDE/HephaistosMac/Resources/hephaistos-icon.svg"),
    ("cerbere", "EGIDE/CerbereMac/Resources/cerbere-icon.svg"),
    ("iris", "EGIDE/Modules/IrisKit/iris-icon.svg"),
    ("mnemosyne", "EGIDE/Modules/MnemosyneKit/mnemosyne-icon.svg"),
    // Logo de l'en-tête de l'accueil.
    ("egide", "EGIDE/Egide/Resources/egide-icon.svg"),
]
let catalogues = ["Egide/Resources/Assets.xcassets", "EgideMac/Resources/Assets.xcassets"]

for (module, chemin) in sources {
    let url = soft.appending(path: chemin)
    guard let image = NSImage(contentsOf: url) else { fatalError("Icône illisible : \(url.path)") }
    let contexte = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    NSGraphicsContext.current = NSGraphicsContext(cgContext: contexte, flipped: false)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 512, height: 512).fill()
    image.draw(in: NSRect(x: 0, y: 0, width: 512, height: 512))
    let png = NSBitmapImageRep(cgImage: contexte.makeImage()!).representation(using: .png, properties: [:])!
    // EgideMac/ only exists once the Mac app is in this checkout.
    for catalogue in catalogues where FileManager.default.fileExists(atPath: catalogue) {
        let dossier = URL(fileURLWithPath: "\(catalogue)/Icone-\(module).imageset")
        try! FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        try! png.write(to: dossier.appending(path: "icone-\(module).png"))
        let contents = #"{"images":[{"filename":"icone-\#(module).png","idiom":"universal"}],"info":{"author":"xcode","version":1}}"#
        try! contents.write(to: dossier.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
    }
    print("Icone-\(module)")
}

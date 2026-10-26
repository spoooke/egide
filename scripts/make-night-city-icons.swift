// Night City versions of the module icons for Égide on the iPhone: Icone-<module>-nuit, 512 px.
// Recolours the classic icons (blue line on a pale background): the background turns near-black,
// the blue line neon yellow, warm accents neon red. The Égide logo keeps its classic icon.
// Run after scripts/make-module-icons.swift: swift scripts/make-night-city-icons.swift
import AppKit

let modules = ["argos", "hermes", "muse", "money", "hephaistos", "cerbere", "iris", "mnemosyne"]
let catalogue = "Egide/Resources/Assets.xcassets"

let fondHaut: (Double, Double, Double) = (0x16 / 255, 0x12 / 255, 0x1E / 255)
let fondBas: (Double, Double, Double) = (0x24 / 255, 0x0B / 255, 0x18 / 255)
let jaune: (Double, Double, Double) = (0xFC / 255, 0xEE / 255, 0x0A / 255)
let rouge: (Double, Double, Double) = (0xFF / 255, 0x00 / 255, 0x3C / 255)

func melange(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
    (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
}

for module in modules {
    let source = "\(catalogue)/Icone-\(module).imageset/icone-\(module).png"
    guard let image = NSImage(contentsOfFile: source),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("Icône illisible : \(source)") }
    let taille = 512
    let contexte = CGContext(data: nil, width: taille, height: taille, bitsPerComponent: 8, bytesPerRow: taille * 4,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    contexte.draw(cg, in: CGRect(x: 0, y: 0, width: taille, height: taille))
    let pixels = contexte.data!.bindMemory(to: UInt8.self, capacity: taille * taille * 4)

    for y in 0..<taille {
        // Rows run top to bottom in memory.
        let fond = melange(fondHaut, fondBas, Double(y) / Double(taille - 1))
        for x in 0..<taille {
            let i = (y * taille + x) * 4
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            // How much "ink": 0 on the white / pale blue background, 1 on the icon's blue line.
            let encre = min(1, max(0, (0.88 - min(r, g, b)) / 0.6))
            let chaud = r > b + 0.15 && r > g
            let c = melange(fond, chaud ? rouge : jaune, encre)
            pixels[i] = UInt8(c.0 * 255); pixels[i + 1] = UInt8(c.1 * 255); pixels[i + 2] = UInt8(c.2 * 255)
        }
    }

    let png = NSBitmapImageRep(cgImage: contexte.makeImage()!).representation(using: .png, properties: [:])!
    let dossier = URL(fileURLWithPath: "\(catalogue)/Icone-\(module)-nuit.imageset")
    try! FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
    try! png.write(to: dossier.appending(path: "icone-\(module)-nuit.png"))
    let contents = #"{"images":[{"filename":"icone-\#(module)-nuit.png","idiom":"universal"}],"info":{"author":"xcode","version":1}}"#
    try! contents.write(to: dossier.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
    print("Icone-\(module)-nuit")
}

// Rend l'icône de Money (PactoleMac/Resources/money-icon.svg) en PNG pour l'app Mac.
// swift scripts/make-money-icon.swift
import AppKit

let svg = "PactoleMac/Resources/money-icon.svg"
let dossier = "PactoleMac/Resources/Assets.xcassets/AppIcon.appiconset"
guard let image = NSImage(contentsOfFile: svg) else { fatalError("SVG illisible : \(svg)") }

/// macOS ne masque pas l'icône : carré arrondi de 824 px sur 1024 (gabarit Apple), avec une ombre légère.
func rendu(_ taille: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: taille, pixelsHigh: taille, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(taille) / 1024
    let cadre = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let forme = NSBezierPath(roundedRect: cadre, xRadius: 185 * s, yRadius: 185 * s)
    let ombre = NSShadow()
    ombre.shadowColor = NSColor.black.withAlphaComponent(0.3)
    ombre.shadowOffset = NSSize(width: 0, height: -10 * s)
    ombre.shadowBlurRadius = 20 * s
    NSGraphicsContext.saveGraphicsState()
    ombre.set()
    NSColor.white.setFill()
    forme.fill()
    NSGraphicsContext.restoreGraphicsState()
    forme.addClip()
    image.draw(in: cadre)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(atPath: dossier, withIntermediateDirectories: true)
var images: [String] = []
for point in [16, 32, 128, 256, 512] {
    for echelle in [1, 2] {
        let nom = "mac-\(point)\(echelle == 2 ? "@2x" : "").png"
        try rendu(point * echelle).write(to: URL(fileURLWithPath: "\(dossier)/\(nom)"))
        images.append(#"    { "idiom" : "mac", "scale" : "\#(echelle)x", "size" : "\#(point)x\#(point)", "filename" : "\#(nom)" }"#)
    }
}
let contents = "{\n  \"images\" : [\n\(images.joined(separator: ",\n"))\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try contents.write(toFile: "\(dossier)/Contents.json", atomically: true, encoding: .utf8)
try #"{ "info" : { "author" : "xcode", "version" : 1 } }"#.write(toFile: "PactoleMac/Resources/Assets.xcassets/Contents.json",
                                                                 atomically: true, encoding: .utf8)
print("Icône écrite dans \(dossier)")

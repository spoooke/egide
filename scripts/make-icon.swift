// Rend l'icône d'Égide (Egide/Resources/egide-icon.svg) en PNG 1024 × 1024 opaque pour iOS.
// Fond bleu franc et bouclier de verre blanc qui porte la grille des apps.
// swift scripts/make-icon.swift
import AppKit

let svg = "Egide/Resources/egide-icon.svg"
let sortie = "Egide/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
guard let image = NSImage(contentsOfFile: svg) else { fatalError("SVG illisible : \(svg)") }

// Sans couche alpha : iOS veut une icône opaque (il arrondit les coins lui-même).
let contexte = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.current = NSGraphicsContext(cgContext: contexte, flipped: false)
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
try! NSBitmapImageRep(cgImage: contexte.makeImage()!).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: sortie))
print("Icône écrite : \(sortie)")

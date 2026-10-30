// Renders resources/icon.svg to the iOS app icon (an opaque 1024x1024 PNG).
//
//   swift scripts/render-icon.swift   (from app/)
//
// Uses AppKit's built-in SVG support, so it needs nothing beyond macOS.
import AppKit

let app = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let svg = app.appendingPathComponent("resources/icon.svg")
let out = app.appendingPathComponent("ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png")

guard let image = NSImage(contentsOf: svg) else { fatalError("could not load \(svg.path)") }
let size = 1024
// No alpha channel: App Store icons must be opaque.
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("no context") }
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
guard let cg = ctx.makeImage(),
      let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { fatalError("render failed") }
try png.write(to: out)
print("wrote \(out.path)")

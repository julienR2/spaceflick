// Renders assets/AppIcon.icns + assets/icon.png.
// Run via ./assets/make-icon.sh — no design tool, no binary blobs in git.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024          // full icon canvas
let art: CGFloat = 824              // Apple's art box inside it (Big Sur+ spec)
let inset = (canvas - art) / 2

// A superellipse, which is what gives Apple icons their continuous corners —
// a plain rounded rect reads subtly wrong next to the rest of the Dock.
func squircle(in rect: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * pow(abs(ct), 2 / n) * (ct < 0 ? -1 : 1)
        let y = cy + b * pow(abs(st), 2 / n) * (st < 0 ? -1 : 1)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

func render(size: CGFloat) -> CGImage {
    let s = size / canvas
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    let box = CGRect(x: inset, y: inset, width: art, height: art)
    let body = squircle(in: box)

    // Indigo → violet, lit from the top like every other macOS icon.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(srgbRed: 0.52, green: 0.44, blue: 1.00, alpha: 1),
        CGColor(srgbRed: 0.36, green: 0.22, blue: 0.86, alpha: 1),
        CGColor(srgbRed: 0.16, green: 0.10, blue: 0.52, alpha: 1),
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: inset, y: canvas - inset),
                           end: CGPoint(x: canvas - inset, y: inset), options: [])

    // Faint top highlight, so it doesn't read as flat cardboard.
    let gloss = CGGradient(colorsSpace: cs, colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.00),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: canvas - inset),
                           end: CGPoint(x: 0, y: canvas * 0.52), options: [])
    ctx.restoreGState()

    // Everything below is positioned in the art box's own 0…824 space.
    // Two spaces: the one you left, dim; the one you landed on, solid white.
    // Between them, the slivers the panel left behind on its way over.
    ctx.saveGState()
    ctx.translateBy(x: inset, y: inset)

    func panel(_ x: CGFloat, _ w: CGFloat, _ r: CGFloat, _ alpha: CGFloat) {
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha))
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: 262, width: w, height: 300),
                           cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.fillPath()
    }

    panel(96, 236, 52, 0.30)   // the space you came from
    panel(392,  38, 19, 0.34)  // trail
    panel(458,  50, 19, 0.56)  // trail, closer, brighter
    panel(534, 204, 52, 1.00)  // where you are now, already arrived

    ctx.restoreGState()
    return ctx.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(path)") }
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
// iconutil wants exactly these names.
let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
let iconset = "\(outDir)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for (name, size) in variants { write(render(size: size), to: "\(iconset)/\(name).png") }
write(render(size: 1024), to: "\(outDir)/icon.png")
write(render(size: 256), to: "\(outDir)/icon-256.png")
print("rendered \(variants.count) sizes")

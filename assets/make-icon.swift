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
    ctx.saveGState()
    ctx.translateBy(x: inset, y: inset)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Motion trail: the swipe you already made, still in flight.
    let streaks: [(y: CGFloat, x0: CGFloat, x1: CGFloat, w: CGFloat, a: CGFloat)] = [
        (412,  96, 306, 58, 0.95),
        (300, 156, 292, 46, 0.55),
        (524, 156, 292, 46, 0.55),
    ]
    for s in streaks {
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: s.a))
        ctx.setLineWidth(s.w)
        ctx.move(to: CGPoint(x: s.x0, y: s.y))
        ctx.addLine(to: CGPoint(x: s.x1, y: s.y))
        ctx.strokePath()
    }

    // The chevron: where it lands, immediately.
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5))
    ctx.setLineWidth(60)
    ctx.move(to: CGPoint(x: 398, y: 250))
    ctx.addLine(to: CGPoint(x: 536, y: 412))
    ctx.addLine(to: CGPoint(x: 398, y: 574))
    ctx.strokePath()

    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineWidth(76)
    ctx.move(to: CGPoint(x: 566, y: 226))
    ctx.addLine(to: CGPoint(x: 742, y: 412))
    ctx.addLine(to: CGPoint(x: 566, y: 598))
    ctx.strokePath()

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

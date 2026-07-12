// Renders the SK Note Taker app icon (mirrors assets/logo.svg) to PNG with CoreGraphics.
// Usage: swift icongen.swift <output.png> [size]
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: icongen <output.png> [size]\n".utf8))
    exit(1)
}
let outputPath = args[1]
let size = args.count >= 3 ? Int(args[2]) ?? 1024 : 1024
let s = CGFloat(size) / 512.0   // scale factor from the 512 design grid

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                    bytesPerRow: 0, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Flip to SVG-style top-left origin.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x * s, y: y * s, width: w * s, height: h * s),
           cornerWidth: min(r, w / 2) * s, cornerHeight: min(r, h / 2) * s, transform: nil)
}

// Tile with brand gradient.
let tile = rounded(32, 32, 448, 448, 108)
ctx.addPath(tile)
ctx.clip()
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [CGColor(red: 0.31, green: 0.27, blue: 0.90, alpha: 1),
             CGColor(red: 0.08, green: 0.72, blue: 0.65, alpha: 1)] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: 32 * s, y: 32 * s),
                       end: CGPoint(x: 480 * s, y: 480 * s), options: [])

// Top highlight.
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.07))
ctx.addPath(rounded(32, 32, 448, 224, 108))
ctx.fillPath()

// Soundwave bars.
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
let bars: [(CGFloat, CGFloat, CGFloat)] = [   // x, y, height
    (128, 216, 120), (188, 164, 184), (248, 128, 256), (308, 188, 136), (368, 152, 152),
]
for (x, y, h) in bars {
    ctx.addPath(rounded(x, y, 34, h, 17))
    ctx.fillPath()
}

// Note dot.
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
ctx.fillEllipse(in: CGRect(x: (265 - 18) * s, y: (404 - 18) * s, width: 36 * s, height: 36 * s))

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: outputPath) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outputPath) (\(size)x\(size))")

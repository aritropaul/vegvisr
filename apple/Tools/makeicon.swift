//  makeicon.swift
//  Builds AppIcon.appiconset from one square source image.
//
//  Run: swift apple/Tools/makeicon.swift <source.png> <Assets.xcassets path>
//
//  The two platforms want different things from the same artwork, which is why
//  this exists rather than a pile of `sips` calls:
//
//    iOS  — full bleed. The system masks the icon itself, so any rounding baked
//           in here would be clipped twice and show as a dark fringe.
//    macOS — the artwork sits on a transparent canvas as a rounded tile
//           occupying 824 of 1024 points, which is the proportion every stock
//           icon uses. A full-bleed square reads as oversized next to them in
//           the Dock, and a square-cornered one reads as broken.
//
//  The macOS corner is a superellipse, not a rounded rectangle: Apple's shape
//  has continuously varying curvature, and CoreGraphics has no primitive for
//  it, so it is traced from |x|^n + |y|^n = 1.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func die(_ m: String) -> Never {
    FileHandle.standardError.write("makeicon: \(m)\n".data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 3 else { die("usage: makeicon <source.png> <Assets.xcassets>") }
let srcURL = URL(fileURLWithPath: args[1])
let catalog = URL(fileURLWithPath: args[2])

guard let srcData = CGImageSourceCreateWithURL(srcURL as CFURL, nil),
      let source = CGImageSourceCreateImageAtIndex(srcData, 0, nil) else {
    die("cannot read \(srcURL.path)")
}
guard source.width == source.height else {
    die("source must be square, got \(source.width)x\(source.height)")
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func context(_ side: Int) -> CGContext {
    guard let c = CGContext(data: nil, width: side, height: side,
                            bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        die("cannot make a \(side)px context")
    }
    c.interpolationQuality = .high
    return c
}

/// Apple's icon corner, traced from a superellipse. n = 5 matches the stock
/// shape closely; 4 is visibly too round and 8 too boxy.
func squircle(in rect: CGRect, n: Double = 5, steps: Int = 720) -> CGPath {
    let p = CGMutablePath()
    let a = Double(rect.width) / 2, b = Double(rect.height) / 2
    let cx = Double(rect.midX), cy = Double(rect.midY)
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * Double.pi
        let ct = cos(t), st = sin(t)
        // Signed |cos|^(2/n) keeps the curve continuous through the axes.
        let x = cx + a * copysign(pow(abs(ct), 2 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2 / n), st)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

func write(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        die("cannot write \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { die("encode failed for \(url.lastPathComponent)") }
}

/// Where the artwork actually is, as opposed to where its file edges are.
///
/// Scaling the whole source into the icon box shrinks the subject twice: once
/// by the source's own margins, once by the icon's. Measured here instead, so
/// framing is driven by the artwork rather than by how it was exported. The
/// background is read from a corner pixel, which is what makes this safe for
/// any flat-backed render.
let contentBox: CGRect = {
    let n = source.width
    var px = [UInt8](repeating: 0, count: n * n * 4)
    let probe = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8,
                          bytesPerRow: n * 4, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    probe.draw(source, in: CGRect(x: 0, y: 0, width: n, height: n))
    let background = Int(px[0]) + Int(px[1]) + Int(px[2])
    var minX = n, minY = n, maxX = -1, maxY = -1
    for y in 0..<n {
        for x in 0..<n {
            let i = (y * n + x) * 4
            guard Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) > background + 30 else { continue }
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }
    }
    guard maxX >= minX else { return CGRect(x: 0, y: 0, width: n, height: n) }
    // Row 0 of a CGBitmapContext is the bottom row, so this is already in the
    // same orientation the drawing below uses. No flip.
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}()

/// Draw the source so its content box fills `fill` of `box`, centred.
///
/// The whole image is drawn and the excess clipped, rather than cropping the
/// CGImage: a crop rect can fall outside the image and has the opposite y
/// convention, and neither failure would be obvious in the output.
func place(_ c: CGContext, in box: CGRect, fill: CGFloat) {
    let subject = max(contentBox.width, contentBox.height)
    let k = fill * min(box.width, box.height) / subject
    let full = CGFloat(source.width) * k
    let centre = CGPoint(x: contentBox.midX * k, y: contentBox.midY * k)
    c.draw(source, in: CGRect(x: box.midX - centre.x, y: box.midY - centre.y,
                              width: full, height: full))
}

/// Full bleed, for iOS. The subject stays clear of the corners the system
/// rounds off.
func flat(_ side: Int) -> CGImage {
    let c = context(side)
    let box = CGRect(x: 0, y: 0, width: side, height: side)
    c.clip(to: box)
    place(c, in: box, fill: 0.80)
    return c.makeImage()!
}

/// Rounded tile on a transparent canvas, for macOS.
func tile(_ side: Int) -> CGImage {
    let c = context(side)
    // 824/1024 is the content box every stock macOS icon fills.
    let inset = CGFloat(side) * (1024 - 824) / 2 / 1024
    let box = CGRect(x: inset, y: inset,
                     width: CGFloat(side) - inset * 2, height: CGFloat(side) - inset * 2)
    c.addPath(squircle(in: box))
    c.clip()
    place(c, in: box, fill: 0.86)
    return c.makeImage()!
}

let set = catalog.appendingPathComponent("AppIcon.appiconset")
try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

// macOS needs seven distinct pixel sizes to satisfy ten idiom/scale entries.
let macSides = [16, 32, 64, 128, 256, 512, 1024]
for s in macSides {
    write(tile(s), to: set.appendingPathComponent("mac-\(s).png"))
}
write(flat(1024), to: set.appendingPathComponent("ios-1024.png"))

struct Entry: Encodable {
    let filename: String
    let idiom: String
    let scale: String?
    let size: String
    let platform: String?
}

var entries: [Entry] = [
    Entry(filename: "ios-1024.png", idiom: "universal", scale: nil,
          size: "1024x1024", platform: "ios")
]
// (point size, scale) -> pixels
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                    (256, 1), (256, 2), (512, 1), (512, 2)] {
    entries.append(Entry(filename: "mac-\(pt * scale).png", idiom: "mac",
                         scale: "\(scale)x", size: "\(pt)x\(pt)", platform: nil))
}

struct Catalog: Encodable {
    struct Info: Encodable { let author = "xcode"; let version = 1 }
    let images: [Entry]
    let info = Info()
}

let enc = JSONEncoder()
enc.outputFormatting = [.prettyPrinted, .sortedKeys]
try enc.encode(Catalog(images: entries))
    .write(to: set.appendingPathComponent("Contents.json"))
try enc.encode(Catalog(images: []))
    .write(to: catalog.appendingPathComponent("Contents.json"))

print("wrote \(macSides.count) macOS tiles + 1 iOS image to \(set.path)")

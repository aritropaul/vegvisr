// Renders what the app's Metal layer composites, straight to PNG, so the
// rasteriser output can be eyeballed without a screen-capture permission.
import Worldgen
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/vegvisr"
let seed = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "j3QV2ftr3y"

func writePNG(_ rgba: [UInt8], _ w: Int, _ h: Int, _ path: String) {
    let cs = CGColorSpaceCreateDeviceRGB()
    var data = rgba
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: w * 4, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let img = ctx.makeImage()!
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

let t0 = Date()
let wg = WorldGenerator(seedName: seed, worldGenVersion: 2)
FileHandle.standardError.write("pregenerate \(Int(Date().timeIntervalSince(t0)*1000))ms\n".data(using: .utf8)!)

// One 1024² view of the whole world per mode/palette, matching what the app
// shows at the default camera.
let S = 1024
let tr = TileRenderer(wg)
for (mode, pal, tag) in [(Mode.biome, Palette.classic, "biome-std"),
                          (Mode.terrain, Palette.classic, "terrain-std"),
                          (Mode.terrain, Palette.accessible, "terrain-a11y")] {
    let t = Date()
    tr.render(ox: -10500, oy: 10500, span: 21000, size: S, mode: mode, palette: pal)
    let ms = Int(Date().timeIntervalSince(t) * 1000)
    let px = tr.copyPixels()
    writePNG(px, S, S, "\(out)-\(tag).png")
    FileHandle.standardError.write("\(tag) \(S)x\(S) \(ms)ms\n".data(using: .utf8)!)
}

// A zoomed view around spawn, terrain mode, to show contours + shoreline.
tr.render(ox: -2000, oy: 2000, span: 4000, size: S, mode: .terrain, palette: .classic)
writePNG(tr.copyPixels(), S, S, "\(out)-spawn.png")
FileHandle.standardError.write("spawn detail written\n".data(using: .utf8)!)
